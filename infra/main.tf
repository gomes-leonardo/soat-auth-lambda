locals {
  prefix       = "soat-${var.environment}"
  param_prefix = "/soat/${var.environment}"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Segredo do webhook do notifier. Gerado aqui, lido pela funcao em runtime e
# pelo Terraform de alertas do New Relic (soat-infra-k8s/newrelic).
# ---------------------------------------------------------------------------

resource "random_password" "notifier_webhook" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "notifier_webhook" {
  name        = "${local.param_prefix}/notifier/webhook-secret"
  description = "Segredo Bearer que o New Relic apresenta ao notifier"
  type        = "SecureString"
  value       = random_password.notifier_webhook.result
}

# ---------------------------------------------------------------------------
# Segredo de origem: o Kong o injeta no header X-Soat-Origin. Sem ele a funcao
# de autenticacao recusa a chamada, entao bater direto na Function URL nao
# contorna o rate limit do gateway.
# ---------------------------------------------------------------------------

resource "random_password" "auth_origin" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "auth_origin" {
  name        = "${local.param_prefix}/auth/origin-secret"
  description = "Header que o Kong apresenta a funcao de autenticacao por CPF"
  type        = "SecureString"
  value       = random_password.auth_origin.result
}

# ---------------------------------------------------------------------------
# Um papel por funcao, cada um so com os parametros que le. Os dois nascem com
# o permissions boundary do bootstrap: o pipeline nao consegue criar papel
# mais poderoso que isso.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/soat-function-boundary"
  param_arn    = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.param_prefix}"
}

resource "aws_iam_role" "auth_cpf" {
  name                 = "${local.prefix}-auth-cpf"
  assume_role_policy   = data.aws_iam_policy_document.assume_lambda.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "auth_cpf" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.auth_cpf.arn}:*"]
  }
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.param_arn}/db/url",
      "${local.param_arn}/jwt/secret",
      aws_ssm_parameter.auth_origin.arn,
    ]
  }
}

resource "aws_iam_role_policy" "auth_cpf" {
  name   = "${local.prefix}-auth-cpf"
  role   = aws_iam_role.auth_cpf.id
  policy = data.aws_iam_policy_document.auth_cpf.json
}

resource "aws_iam_role" "notifier" {
  name                 = "${local.prefix}-notifier"
  assume_role_policy   = data.aws_iam_policy_document.assume_lambda.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "notifier" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notifier.arn}:*"]
  }
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.notifier_webhook.arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "notifier" {
  name   = "${local.prefix}-notifier"
  role   = aws_iam_role.notifier.id
  policy = data.aws_iam_policy_document.notifier.json
}

# ---------------------------------------------------------------------------
# Funcoes. Sem concorrencia reservada: a conta tem limite de 10 execucoes
# simultaneas e a AWS exige que as 10 fiquem livres. Risco residual aceito: as
# duas funcoes disputam as mesmas 10 vagas. Contencao: segredo de origem na
# autenticacao (so o Kong chama, com rate limit) e segredo Bearer no notifier.
# ---------------------------------------------------------------------------

data "archive_file" "auth_cpf" {
  type        = "zip"
  source_file = "${var.dist_dir}/auth-cpf/index.js"
  output_path = "${path.module}/.build/auth-cpf.zip"
}

data "archive_file" "notifier" {
  type        = "zip"
  source_file = "${var.dist_dir}/notifier/index.js"
  output_path = "${path.module}/.build/notifier.zip"
}

resource "aws_cloudwatch_log_group" "auth_cpf" {
  name              = "/aws/lambda/${local.prefix}-auth-cpf"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/${local.prefix}-notifier"
  retention_in_days = 7
}

resource "aws_lambda_function" "auth_cpf" {
  function_name    = "${local.prefix}-auth-cpf"
  description      = "Valida o CPF, consulta o cliente e devolve JWT de cliente"
  role             = aws_iam_role.auth_cpf.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.auth_cpf.output_path
  source_code_hash = data.archive_file.auth_cpf.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      DB_URL_PARAM        = "${local.param_prefix}/db/url"
      JWT_SECRET_PARAM    = "${local.param_prefix}/jwt/secret"
      ORIGIN_SECRET_PARAM = aws_ssm_parameter.auth_origin.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.auth_cpf]
}

resource "aws_lambda_function_url" "auth_cpf" {
  function_name      = aws_lambda_function.auth_cpf.function_name
  authorization_type = "NONE"
}

# Function URL com autorizacao NONE ainda exige politica de recurso: sem ela
# toda chamada recebe 403. Desde 2025 sao duas permissoes, a da URL e a de
# invocar a funcao por ela.
resource "aws_lambda_permission" "auth_cpf_url" {
  statement_id           = "FunctionUrlPublic"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.auth_cpf.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "auth_cpf_invoke" {
  statement_id             = "FunctionUrlInvoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.auth_cpf.function_name
  principal                = "*"
  invoked_via_function_url = true
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${local.prefix}-notifier"
  description      = "Recebe alertas do New Relic e publica no SNS"
  role             = aws_iam_role.notifier.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      ENVIRONMENT          = var.environment
      ALERT_TOPIC_ARN      = aws_sns_topic.alerts.arn
      WEBHOOK_SECRET_PARAM = aws_ssm_parameter.notifier_webhook.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.notifier]
}

resource "aws_lambda_function_url" "notifier" {
  function_name      = aws_lambda_function.notifier.function_name
  authorization_type = "NONE"
}

# Function URL com autorizacao NONE ainda exige politica de recurso: sem ela
# toda chamada recebe 403. Desde 2025 sao duas permissoes, a da URL e a de
# invocar a funcao por ela.
resource "aws_lambda_permission" "notifier_url" {
  statement_id           = "FunctionUrlPublic"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.notifier.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "notifier_invoke" {
  statement_id             = "FunctionUrlInvoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.notifier.function_name
  principal                = "*"
  invoked_via_function_url = true
}

# A URL do notifier tambem vai para o SSM: o Terraform do New Relic a le dali.
resource "aws_ssm_parameter" "notifier_url" {
  name  = "${local.param_prefix}/notifier/url"
  type  = "String"
  value = aws_lambda_function_url.notifier.function_url
}

# ---------------------------------------------------------------------------
# Topico de alertas, entregue por e-mail. A confirmacao da assinatura e o
# unico passo manual: a AWS manda um link para o endereco.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
