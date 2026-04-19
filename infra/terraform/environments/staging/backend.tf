terraform {
  backend "s3" {
    bucket         = "amnix-terraform-state"
    key            = "environments/staging/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "amnix-terraform-state-locks"
  }
}
