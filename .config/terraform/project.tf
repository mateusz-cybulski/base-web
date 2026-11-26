# This project's additions to the platform. Yours: `mise run platform` never changes this file.
locals {
  # Secrets your own resources create, by secret id, e.g.
  # "maps-api-key" = google_apikeys_key.maps.key_string
  generated_secrets = {}

  # Plain environment variables per service, e.g. { api = { STORAGE_BUCKET = google_storage_bucket.files.name } }
  extra_env = {}

  # Google APIs your own resources need, e.g. ["storage.googleapis.com"]
  extra_services_to_enable = []
}
