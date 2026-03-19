# Backend منفصل تماماً عن production
# State محفوظ في S3 bucket في eu-west-1
terraform {
  backend "s3" {
    bucket         = "platform-terraform-state-eu"
    key            = "eu-west-1/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "platform-terraform-locks-eu"
  }
}
