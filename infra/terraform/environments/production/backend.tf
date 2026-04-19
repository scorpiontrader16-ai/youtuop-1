terraform {
  backend "s3" {
    bucket         = "amnix-terraform-state"
    key            = "environments/production/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "amnix-terraform-state-locks"
  }
}
