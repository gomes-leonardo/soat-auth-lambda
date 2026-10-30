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
# Papel das funcoes: logs, leitura dos parametros do proprio ambiente e
# publicacao no topico de alertas. Nada alem disso.
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

resource "aws_iam_role" "functions" {
  name               = "${local.prefix}-functions"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "functions" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.auth_cpf.arn}:*", "${aws_cloudwatch_log_group.notifier.arn}:*"]
  }

  statement {
    sid       = "ReadEnvironmentParameters"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.param_prefix}/*"]
  }

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "functions" {
  name   = "${local.prefix}-functions"
  role   = aws_iam_role.functions.id
  policy = data.aws_iam_policy_document.functions.json
}

# ---------------------------------------------------------------------------
# Funcoes. Sem concorrencia reservada: a conta tem limite de 10 execucoes
# simultaneas e a AWS exige que as 10 fiquem livres. A contencao de abuso fica
# no rate limit do Kong (auth) e no segredo do webhook (notifier).
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
  role             = aws_iam_role.functions.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.auth_cpf.output_path
  source_code_hash = data.archive_file.auth_cpf.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      DB_URL_PARAM     = "${local.param_prefix}/db/url"
      JWT_SECRET_PARAM = "${local.param_prefix}/jwt/secret"
    }
  }

  depends_on = [aws_cloudwatch_log_group.auth_cpf]
}

resource "aws_lambda_function_url" "auth_cpf" {
  function_name      = aws_lambda_function.auth_cpf.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${local.prefix}-notifier"
  description      = "Recebe alertas do New Relic e publica no SNS"
  role             = aws_iam_role.functions.arn
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
