terraform {
  backend "http" {
    address        = "http://localhost:4000/tf/dev/infra/production/state"
    lock_address   = "http://localhost:4000/tf/dev/infra/production/lock"
    unlock_address = "http://localhost:4000/tf/dev/infra/production/unlock"
    lock_method    = "POST"
    unlock_method  = "POST"
  }
}

resource "null_resource" "demo" {
  triggers = { now = timestamp() }
}