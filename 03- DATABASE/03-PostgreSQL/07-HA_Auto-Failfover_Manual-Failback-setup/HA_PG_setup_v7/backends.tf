terraform {
  backend "gcs" {
    bucket = "cs-tfstate-me-central2-3dd9623b1e4c4a37b15ad1ea49c11ff2"
    prefix = "terraform/databases/"
    # prefix = "terraform/databases/${terraform.workspace}"
  }
}
