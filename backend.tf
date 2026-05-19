terraform {
  backend "gcs" {
    bucket = "fafa-tf-state"
    prefix = "fafa-iac"
  }
}
