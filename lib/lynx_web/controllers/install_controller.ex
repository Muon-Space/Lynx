defmodule LynxWeb.InstallController do
  use LynxWeb, :controller

  alias Lynx.Service.Install
  alias Lynx.Service.ValidatorService

  @admin_name_min_length 2
  @admin_name_max_length 60
  @app_name_min_length 2
  @app_name_max_length 60

  def install(conn, params) do
    if not Install.is_installed() do
      case validate_install_request(params) do
        {:ok, _} ->
          app_key = Install.get_app_key()

          Install.store_configs(%{
            app_name: params["app_name"] || "Lynx",
            app_url: params["app_url"] || "http://lynx.sh",
            app_email: params["app_email"] || "no_reply@lynx.sh",
            app_key: app_key
          })

          Install.create_admin(%{
            admin_name: params["admin_name"] || "",
            admin_email: params["admin_email"] || "",
            admin_password: params["admin_password"] || "",
            app_key: app_key
          })

          conn
          |> put_status(:ok)
          |> put_view(LynxWeb.MiscJSON)
          |> render(:success, %{message: "Application installed successfully"})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> put_view(LynxWeb.MiscJSON)
          |> render(:error, %{message: reason})
      end
    else
      conn
      |> put_status(:bad_request)
      |> put_view(LynxWeb.MiscJSON)
      |> render(:error, %{message: "Application is installed"})
    end
  end

  defp validate_install_request(params) do
    errs = %{
      app_name_required: "Application name is required",
      app_name_invalid: "Application name is invalid",
      app_url_required: "Application URL is required",
      app_url_invalid: "Application URL is invalid",
      app_email_required: "Application email is required",
      app_email_invalid: "Application email is invalid",
      admin_name_required: "User name is required",
      admin_name_invalid: "User name is invalid",
      admin_email_required: "User email is required",
      admin_email_invalid: "User email is invalid",
      admin_password_required: "User password is required",
      admin_password_invalid:
        "User password is invalid, It must be alphanumeric and not less than 6 characters"
    }

    with {:ok, _} <- ValidatorService.is_string?(params["app_name"], errs.app_name_required),
         {:ok, _} <- ValidatorService.is_string?(params["app_url"], errs.app_url_required),
         {:ok, _} <- ValidatorService.is_string?(params["app_email"], errs.app_email_required),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["app_name"],
             @app_name_min_length,
             @app_name_max_length,
             errs.app_name_invalid
           ),
         {:ok, _} <- ValidatorService.is_url?(params["app_url"], errs.app_url_invalid),
         {:ok, _} <- ValidatorService.is_email?(params["app_email"], errs.app_email_invalid),
         {:ok, _} <- ValidatorService.is_string?(params["admin_name"], errs.admin_name_required),
         {:ok, _} <- ValidatorService.is_string?(params["admin_email"], errs.admin_email_required),
         {:ok, _} <-
           ValidatorService.is_string?(params["admin_password"], errs.admin_password_required),
         {:ok, _} <-
           ValidatorService.is_not_empty?(params["admin_name"], errs.admin_name_required),
         {:ok, _} <-
           ValidatorService.is_not_empty?(params["admin_email"], errs.admin_email_required),
         {:ok, _} <-
           ValidatorService.is_not_empty?(params["admin_password"], errs.admin_password_required),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["admin_name"],
             @admin_name_min_length,
             @admin_name_max_length,
             errs.admin_name_invalid
           ),
         {:ok, _} <- ValidatorService.is_email?(params["admin_email"], errs.admin_email_invalid),
         {:ok, _} <-
           ValidatorService.is_password?(params["admin_password"], errs.admin_password_invalid) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
