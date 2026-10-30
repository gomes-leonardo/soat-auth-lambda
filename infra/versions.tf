terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # bucket e key chegam por -backend-config no `terraform init` (ver README),
  # uma key por ambiente: soat-auth-lambda/infra/<env>/terraform.tfstate.
  backend "s3" {
    region       = "sa-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "soat"
      Repository  = "soat-auth-lambda"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
