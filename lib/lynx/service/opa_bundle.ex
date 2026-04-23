defmodule Lynx.Service.OPABundle do
  @moduledoc """
  Assembles enabled `policies` rows into an OPA bundle (tar.gz) that OPA
  pulls via its bundle-polling mechanism.

  Bundle layout:

      .manifest              — JSON manifest declaring the `lynx` root
      lynx/policy_<uuid>/policy.rego

  Each generated `.rego` file declares `package lynx.policy_<uuid_with_underscores>`.
  The author's own `package` line in the rego source is rewritten on the fly so
  Lynx owns the namespace and policies can't shadow each other or collide
  with OPA built-ins. Anything else (imports, deny rules, helper functions)
  is preserved verbatim.

  ETag is the latest `policies.updated_at` timestamp (or `"empty"` when no
  policies exist), so OPA's `If-None-Match` poll short-circuits without us
  re-zipping the same bytes on every request.
  """

  alias Lynx.Context.PolicyContext

  @doc """
  Build the bundle as `{etag, body}`. Caches the tarball under the ETag
  via `:persistent_term` — typical bundle is small (a few KB), and OPA
  will hit this once per poll across many pods.
  """
  def build do
    etag = current_etag()

    body =
      case :persistent_term.get({__MODULE__, :body, etag}, :none) do
        :none ->
          fresh = build_tarball(PolicyContext.list_enabled_policies())
          :persistent_term.put({__MODULE__, :body, etag}, fresh)
          fresh

        cached ->
          cached
      end

    {etag, body}
  end

  @doc "Just the ETag — used by the controller to short-circuit on If-None-Match."
  def current_etag do
    case PolicyContext.latest_enabled_update_at() do
      nil ->
        "empty"

      %NaiveDateTime{} = ts ->
        ts |> NaiveDateTime.to_iso8601() |> Base.url_encode64(padding: false)
    end
  end

  @doc """
  Translate a Lynx policy UUID into its OPA package suffix (hyphens →
  underscores so the result is a valid Rego identifier). Exposed so the
  `PolicyEngine.OPA` impl computes the same suffix when querying
  `data.lynx.policy_<suffix>.deny`.
  """
  def package_suffix(uuid) when is_binary(uuid) do
    String.replace(uuid, "-", "_")
  end

  defp build_tarball(policies) do
    files =
      [{".manifest", manifest_json()}] ++ Enum.map(policies, &policy_file/1)

    files
    |> Enum.map(&tar_entry/1)
    |> IO.iodata_to_binary()
    |> Kernel.<>(tar_trailer())
    |> :zlib.gzip()
  end

  defp policy_file(policy) do
    suffix = package_suffix(policy.uuid)
    path = "lynx/policy_#{suffix}/policy.rego"
    body = rewrite_package(policy.rego_source, suffix)
    {path, body}
  end

  # USTAR-format tar entry. Each entry is a 512-byte header followed by the
  # file body padded to a 512-byte multiple. We write our own because OTP's
  # `:erl_tar` only writes to file paths in this version (open/init APIs
  # require us to maintain a stateful in-memory writer with seek tracking).
  # Given our paths are short (<100 chars) and bodies small, the manual
  # format is ~30 lines and avoids both tempfiles and stateful callbacks.
  @block 512

  defp tar_entry({name, body}) when is_binary(name) and is_binary(body) do
    body_size = byte_size(body)
    padding = pad_to_block(body_size)

    header = build_header(name, body_size)
    [header, body, :binary.copy(<<0>>, padding)]
  end

  # The trailing two zero blocks signal end-of-archive per the USTAR spec.
  defp tar_trailer, do: :binary.copy(<<0>>, @block * 2)

  defp pad_to_block(0), do: 0
  defp pad_to_block(n), do: rem(@block - rem(n, @block), @block)

  defp build_header(name, size) do
    name_bytes = name |> pad_field(100)
    mode = octal(0o644, 8)
    uid = octal(0, 8)
    gid = octal(0, 8)
    size_field = octal(size, 12)
    mtime = octal(System.os_time(:second), 12)
    typeflag = "0"
    linkname = pad_field("", 100)
    magic = "ustar\0"
    version = "00"
    uname = pad_field("lynx", 32)
    gname = pad_field("lynx", 32)
    devmajor = octal(0, 8)
    devminor = octal(0, 8)
    prefix = pad_field("", 155)

    # Checksum is computed with the checksum field treated as 8 spaces, then
    # the sum of all 512 header bytes is written as 6 octal digits + NUL + space.
    chksum_placeholder = String.duplicate(" ", 8)

    header_pre =
      [
        name_bytes,
        mode,
        uid,
        gid,
        size_field,
        mtime,
        chksum_placeholder,
        typeflag,
        linkname,
        magic,
        version,
        uname,
        gname,
        devmajor,
        devminor,
        prefix
      ]
      |> IO.iodata_to_binary()
      |> pad_field(@block)

    sum = header_pre |> :binary.bin_to_list() |> Enum.sum()
    chksum_field = :io_lib.format(~c"~6.8.0b", [sum]) |> IO.iodata_to_binary()
    chksum_value = chksum_field <> <<0, ?\s>>

    # Header layout: name (100) + mode (8) + uid (8) + gid (8) + size (12) +
    # mtime (12) + chksum (8) at offset 148. Splice the real chksum in.
    pre = binary_part(header_pre, 0, 148)
    post = binary_part(header_pre, 156, @block - 156)
    pre <> chksum_value <> post
  end

  defp octal(value, width) when is_integer(value) and value >= 0 do
    digits = width - 1
    str = Integer.to_string(value, 8) |> String.pad_leading(digits, "0")
    str <> <<0>>
  end

  # Right-pad with NULs to `width`. If the input is already wider, truncate.
  defp pad_field(bin, width) do
    case byte_size(bin) do
      n when n >= width -> binary_part(bin, 0, width)
      n -> bin <> :binary.copy(<<0>>, width - n)
    end
  end

  # Rego files always start with a `package <name>` line (after optional
  # comments + whitespace). Replace it with the Lynx-controlled namespace.
  # If no package line exists, prepend one — OPA will still parse the rest.
  defp rewrite_package(rego, suffix) do
    namespace = "package lynx.policy_#{suffix}"

    case Regex.run(~r/^\s*package\s+[^\n]+/m, rego, return: :index) do
      [{start, len}] ->
        prefix = binary_part(rego, 0, start)
        rest = binary_part(rego, start + len, byte_size(rego) - start - len)
        prefix <> namespace <> rest

      nil ->
        namespace <> "\n\n" <> rego
    end
  end

  defp manifest_json do
    Jason.encode!(%{"roots" => ["lynx"]})
  end
end
