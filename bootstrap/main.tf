# Aplicado UMA vez, por uma pessoa, com credencial de administrador local:
#   terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply
# Cria o provedor OIDC do GitHub e o papel que os pipelines dos quatro
# repositorios assumem. Sem chave de acesso guardada em secret nenhum.
# State local de proposito: e o que cria o acesso aos outros states.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "sa-east-1"
}

variable "github_owner" {
  type    = string
  default = "gomes-leonardo"
}

variable "repositories" {
  description = "Repositorios cujos pipelines podem assumir o papel."
  type        = list(string)
  default     = ["soat-auth-lambda", "soat-infra-k8s", "soat-infra-db"]
}

variable "state_bucket" {
  type    = string
  default = "tfstate-backend-fiap-leo"
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  # Jobs de deploy declaram `environment`, e o GitHub emite o sub nesse
  # formato. Cada Environment so aceita a sua branch (hml <- develop,
  # prd <- main), configurado no repositorio: pull request nunca chega aqui.
  subjects = flatten([
    for repo in var.repositories : [
      "repo:${var.github_owner}/${repo}:environment:hml",
      "repo:${var.github_owner}/${repo}:environment:prd",
    ]
  ])
  boundary_arn = "arn:aws:iam::${local.account}:policy/soat-function-boundary"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

# Teto de tudo que as funcoes podem fazer. Os papeis que o pipeline cria so
# nascem com este boundary, entao nem um pipeline comprometido cria papel
# com mais poder que isto.
data "aws_iam_policy_document" "function_boundary" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:sa-east-1:${local.account}:log-group:/aws/lambda/soat-*"]
  }
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:sa-east-1:${local.account}:parameter/soat/*"]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = ["arn:aws:sns:sa-east-1:${local.account}:soat-*"]
  }
}

resource "aws_iam_policy" "function_boundary" {
  name   = "soat-function-boundary"
  policy = data.aws_iam_policy_document.function_boundary.json
}

# Fora do padrao soat-* de proposito: o papel de deploy nao pode editar a si
# mesmo pelas permissoes que tem sobre os papeis das funcoes.
resource "aws_iam_role" "deployer" {
  name                 = "gha-soat-deployer"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Escopo por nome: tudo que os pipelines criam comeca com soat-, e todo
# parametro mora em /soat/.
data "aws_iam_policy_document" "deployer" {
  statement {
    sid       = "TerraformState"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}", "arn:aws:s3:::${var.state_bucket}/soat-*"]
  }

  statement {
    sid       = "Lambda"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:sa-east-1:${local.account}:function:soat-*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:sa-east-1:${local.account}:log-group:/aws/lambda/soat-*"]
  }

  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups", "logs:ListTagsForResource"]
    resources = ["*"]
  }

  statement {
    sid       = "Sns"
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:sa-east-1:${local.account}:soat-*"]
  }

  statement {
    sid       = "Parameters"
    actions   = ["ssm:*"]
    resources = ["arn:aws:ssm:sa-east-1:${local.account}:parameter/soat/*"]
  }

  statement {
    sid       = "ParametersDescribe"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid = "FunctionRolesRead"
    actions = [
      "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:GetRolePolicy", "iam:ListInstanceProfilesForRole", "iam:GetPolicy",
      "iam:GetPolicyVersion",
    ]
    resources = ["arn:aws:iam::${local.account}:role/soat-*", aws_iam_policy.function_boundary.arn]
  }

  # Criar papel e escrever politica so com o boundary presente.
  statement {
    sid       = "FunctionRolesWrite"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account}:role/soat-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid = "FunctionRolesMaintain"
    actions = [
      "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::${local.account}:role/soat-*"]
  }

  statement {
    sid       = "PassFunctionRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account}:role/soat-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid    = "KeepBoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion",
      "iam:DeletePolicy", "iam:SetDefaultPolicyVersion",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "gha-soat-deployer"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}

output "role_arn" {
  description = "Va para a variavel AWS_ROLE_ARN dos tres repositorios de infraestrutura."
  value       = aws_iam_role.deployer.arn
}
