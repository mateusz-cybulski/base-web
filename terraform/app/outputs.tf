output "project_id" {
  description = "ID of the created GCP project"
  value       = google_project.app_project.project_id
}

output "project_number" {
  description = "Number of the created GCP project"
  value       = google_project.app_project.number
}

output "region" {
  description = "Region of Cloud Run and Artifact Registry"
  value       = var.GCP_REGION
}

output "service_urls" {
  description = "Public URL of every deployed service"
  value       = { for name, svc in local.services : name => "https://${svc.domain}" }
}

output "service_accounts" {
  description = "Email of every service's own service account, for the project's own IAM bindings"
  value       = { for name, account in google_service_account.service : name => account.email }
}

output "service_domains" {
  description = "Domain of every service"
  value       = local.service_domains
}

output "image_project" {
  description = "Project whose registry holds the images this environment runs (its own, or dev's)"
  value       = local.builds_images ? google_project.app_project.project_id : var.image_source_project
}

output "image_tag" {
  description = "Tag (commit) of the images this environment runs; the next environment is promoted to it"
  value       = var.IMAGE_TAG
}

output "environment" {
  description = "prod, dev or test"
  value       = var.environment
}

