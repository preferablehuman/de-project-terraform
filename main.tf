##############################################
# Terraform – GCP Data‑Engineering Pipeline   #
# Two Buckets, Two Cloud Run Services,        #
# Two Eventarc Triggers, One IAM SA,          #
# and a Cloud SQL for PostgreSQL instance     #
##############################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.33.0"
    }
  }
}

############################
#      INPUT VARIABLES     #
############################

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default = "lamprey-project-autodeploy"
}

variable "region" {
  description = "Primary region for resources"
  type        = string
  default     = "us-central1"
}

variable "bucket_videostore" {
  description = "Name for first GCS bucket"
  type        = string
  default = "<project‑id>-videostore"
}

variable "bucket_textstore" {
  description = "Name for second GCS bucket"
  type        = string
  default = "<project‑id>-textstore"
}

variable "container_videoprocessing" {
  description = "Container image URL for first Cloud Run service"
  type        = string
  default = "preferablehuman/lamprey-locator:latest"
}

variable "container_csvprocessing" {
  description = "Container image URL for second Cloud Run service"
  type        = string
  default = "preferablehuman/csv-processor:latest"
}

variable "db_instance_name" {
  description = "Cloud SQL instance name"
  type        = string
  default     = "lamprey-db"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "postgres"
}

variable "db_user" {
  description = "Database user name"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Password for the database user"
  type        = string
  sensitive   = true
}
variable "create_table_video_detection" {
  description = "create table for"
  type        = string
  default     = <<-SQL
    -- Schema bootstrap for image‑detection pipeline
    CREATE TABLE IF NOT EXISTS public."LAMPREY_DETECTION" (
        "DETECTION_TIME"  NUMERIC(10,1),
        "FRAME_NUMBER"    INTEGER,
        "X_COORDINATE"    INTEGER,
        "Y_COORDINATE"    INTEGER,
        "DETECTION_COUNT" INTEGER,
        "LOCATION"        TEXT,
        "VIDEO_NUMBER"    INTEGER,
        "CAMERA"          TEXT,
        "TIMESTAMP"       TIMESTAMP WITHOUT TIME ZONE
    ) TABLESPACE pg_default;

    ALTER TABLE IF EXISTS public."LAMPREY_DETECTION" OWNER TO postgres;
    SQL
}
variable "create_table_video_detection" {
  description = "create table for"
  type        = string
  default     = <<-SQL
    -- Schema bootstrap for image‑detection pipeline
    CREATE TABLE IF NOT EXISTS public."PIT_DETECTION" (
      "ANTENNA" integer,
      "TAG_ID" text COLLATE pg_catalog."default",
      "TIMESTAMP" timestamp without time zone
    ) TABLESPACE pg_default;

    ALTER TABLE IF EXISTS public."PIT_DETECTION" OWNER to postgres;
    SQL
}

############################
#        PROVIDERS         #
############################

provider "google" {
  project = var.project_id
  region  = var.region
}

############################
#   ENABLE NECESSARY APIs  #
############################

resource "google_project_service" "services" {
  for_each = toset([
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com"
  ])
  service            = each.key
  disable_on_destroy = false
}

############################
#    SERVICE ACCOUNT       #
############################

resource "google_service_account" "pipeline_sa" {
  account_id   = "pipeline-sa"
  display_name = "Pipeline Service Account"
}

locals {
  sa_member = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

resource "google_project_iam_member" "sa_owner" {
  project = var.project_id
  role    = "roles/owner"
  member  = local.sa_member
}

############################
#     STORAGE BUCKETS      #
############################

resource "google_storage_bucket" "videstore" {
  name          = var.bucket_videostore
  location      = var.region
  storage_class = "COLDLINE"
  force_destroy = true
  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "textstore" {
  name          = var.bucket_textstore
  location      = var.region
  storage_class = "COLDLINE"
  force_destroy = true
  uniform_bucket_level_access = true
}

############################
#      CLOUD SQL (PG)      #
############################

resource "google_sql_database_instance" "postgres" {
  name             = var.db_instance_name
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier       = "db-custom-1-3840"
    disk_type  = "PD_SSD"
    disk_size  = 10

    ip_configuration {
      ipv4_enabled = true   # quick start – tighten for prod
      require_ssl = false
    }
  }
}

resource "google_sql_database" "appdb" {
  name     = var.db_name
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "appuser" {
  name     = var.db_user
  instance = google_sql_database_instance.postgres.name
  password = var.db_password
}

############################
#    CLOUD RUN SERVICES    #
############################

resource "google_cloud_run_v2_service" "video-processing" {
  name     = "video-processing"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.pipeline_sa.email
    timeout = "600s"

    containers {
      image = var.container_videoprocessing
      # exemplar ENV passing the DB connection string
      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = google_sql_database_instance.postgres.connection_name
      }
      env { 
        name = "DB_NAME"  
        value = var.db_name
      }
      env { 
        name = "DB_USER"  
        value = var.db_user 
      }
      env { 
        name = "DB_PASS"  
        value = var.db_password 
      }
      env { 
        name = "BUCKET_NAME"  
        value = var.bucket_videostore
      }
    }
  }
  depends_on = [google_project_service.services]
}

resource "google_cloud_run_v2_service" "csv-processing" {
  name     = "csv-processing"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.pipeline_sa.email
    timeout = "600s"
    containers {
      image = var.container_csvprocessing
      # exemplar ENV passing the DB connection string
      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = google_sql_database_instance.postgres.connection_name
      }
      env { 
        name = "DB_NAME"  
        value = var.db_name
      }
      env { 
        name = "DB_USER"  
        value = var.db_user 
      }
      env { 
        name = "DB_PASS"  
        value = var.db_password 
      }
      env { 
        name = "BUCKET_NAME"  
        value = var.bucket_textstore
      }
    }
  }
  depends_on = [google_project_service.services]
}

############################
#      EVENTARC TRIGGERS   #
############################

resource "google_eventarc_trigger" "videotrigger" {
  name     = "trigger-bucket-a-finalized"
  location = var.region
  service_account = google_service_account.pipeline_sa.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }
  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.bucket_videostore.name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.video-processing.name
      region  = var.region
    }
  }
}

resource "google_eventarc_trigger" "csvtrigger" {
  name     = "trigger-bucket-b-finalized"
  location = var.region
  service_account = google_service_account.pipeline_sa.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }
  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.bucket_textstore.name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.csv-processing.name
      region  = var.region
    }
  }
}

############################
#         OUTPUTS          #
############################

output "service_a_url" {
  description = "Public URL for the first Cloud Run service"
  value       = google_cloud_run_v2_service.service_a.uri
}

output "service_b_url" {
  description = "Public URL for the second Cloud Run service"
  value       = google_cloud_run_v2_service.service_b.uri
}

output "cloud_sql_connection_name" {
  description = "Connection string used by the Cloud SQL Auth Proxy"
  value       = google_sql_database_instance.postgres.connection_name
}
