# Disjuntor de custo. Um orcamento mensal de US$ 1 avisa por e-mail no
# primeiro centavo e, ao estourar, publica num topico que dispara a funcao
# cost-guard: ela zera a concorrencia de toda funcao soat-*, e a AWS passa a
# recusar as chamadas sem executar (chamada recusada nao e cobrada).
# O Budgets so notifica uma vez por mes; a mesma funcao roda a cada 6 horas e
# reaplica o bloqueio enquanto o gasto do mes estiver no limite, entao religar
# ou recriar as funcoes nao as deixa desprotegidas. O Budgets atualiza algumas
# vezes por dia, entao o disjuntor age com horas de atraso.
# Fora do padrao soat-* de proposito: o papel de deploy nao o desliga.

variable "alert_email" {
  description = "Recebe o aviso do primeiro centavo e o de disjuntor acionado."
  type        = string
}

resource "aws_sns_topic" "cost_guard" {
  name = "cost-guard"
}

data "aws_iam_policy_document" "cost_guard_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.cost_guard.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

resource "aws_sns_topic_policy" "cost_guard" {
  arn    = aws_sns_topic.cost_guard.arn
  policy = data.aws_iam_policy_document.cost_guard_topic.json
}

resource "aws_budgets_budget" "cost_guard" {
  name         = "soat-cost-guard"
  budget_type  = "COST"
  limit_amount = "1.0"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credito promocional nao esconde o gasto: o orcamento mede o custo bruto.
  cost_types {
    include_credit = false
    include_refund = false
  }

  # So os servicos que o projeto usa: sobras antigas da conta (S3, KMS) nao
  # disparam o disjuntor contra as funcoes.
  cost_filter {
    name = "Service"
    values = [
      "AWS Lambda",
      "Amazon Simple Notification Service",
      "AmazonCloudWatch",
      "CloudWatch Events",
      "Amazon EventBridge",
    ]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 1
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_guard.arn]
  }

  depends_on = [aws_sns_topic_policy.cost_guard]
}

data "archive_file" "cost_guard" {
  type        = "zip"
  output_path = "${path.module}/.build/cost-guard.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      import os

      import boto3

      lambdas = boto3.client("lambda")
      budgets = boto3.client("budgets", region_name="us-east-1")


      def over_budget():
          budget = budgets.describe_budget(
              AccountId=os.environ["ACCOUNT_ID"], BudgetName=os.environ["BUDGET_NAME"]
          )["Budget"]
          # Orcamento recem-criado pode vir sem calculo ainda: conta como zero.
          spent = budget.get("CalculatedSpend", {}).get("ActualSpend", {}).get("Amount", "0")
          print({"spent": spent, "limit": budget["BudgetLimit"]["Amount"]})
          return float(spent) >= float(budget["BudgetLimit"]["Amount"])


      def throttle_all():
          throttled, failed = [], []
          for page in lambdas.get_paginator("list_functions").paginate():
              for fn in page["Functions"]:
                  name = fn["FunctionName"]
                  if not name.startswith("soat-"):
                      continue
                  try:
                      lambdas.put_function_concurrency(
                          FunctionName=name, ReservedConcurrentExecutions=0
                      )
                      throttled.append(name)
                  except Exception as error:
                      failed.append(f"{name}: {error}")
          print({"throttled": throttled, "failed": failed})
          if failed:
              raise RuntimeError(f"nao bloqueou: {failed}")
          return {"throttled": throttled}


      def handler(event, context):
          from_budget = "Records" in event
          if from_budget or over_budget():
              return throttle_all()
          print({"throttled": [], "reason": "dentro do orcamento"})
          return {"throttled": []}
    PY
  }
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cost_guard" {
  name               = "cost-guard"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "cost_guard" {
  statement {
    actions   = ["lambda:ListFunctions"]
    resources = ["*"]
  }
  statement {
    actions   = ["budgets:ViewBudget"]
    resources = ["arn:aws:budgets::${local.account}:budget/${aws_budgets_budget.cost_guard.name}"]
  }
  statement {
    actions   = ["lambda:PutFunctionConcurrency"]
    resources = ["arn:aws:lambda:sa-east-1:${local.account}:function:soat-*"]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cost_guard.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cost_guard" {
  name   = "cost-guard"
  role   = aws_iam_role.cost_guard.id
  policy = data.aws_iam_policy_document.cost_guard.json
}

resource "aws_cloudwatch_log_group" "cost_guard" {
  name              = "/aws/lambda/cost-guard"
  retention_in_days = 7
}

resource "aws_lambda_function" "cost_guard" {
  function_name    = "cost-guard"
  description      = "Zera a concorrencia das funcoes soat-* quando o orcamento estoura"
  role             = aws_iam_role.cost_guard.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.cost_guard.output_path
  source_code_hash = data.archive_file.cost_guard.output_base64sha256
  memory_size      = 128
  timeout          = 30

  environment {
    variables = {
      ACCOUNT_ID  = local.account
      BUDGET_NAME = aws_budgets_budget.cost_guard.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.cost_guard]
}

resource "aws_lambda_permission" "cost_guard_sns" {
  statement_id  = "AllowCostGuardTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_guard.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_guard.arn
}

resource "aws_sns_topic_subscription" "cost_guard" {
  topic_arn = aws_sns_topic.cost_guard.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_guard.arn
}

# O Budgets notifica uma vez por mes; esta checagem reaplica o bloqueio.
resource "aws_cloudwatch_event_rule" "cost_guard" {
  name                = "cost-guard"
  schedule_expression = "rate(6 hours)"
}

resource "aws_cloudwatch_event_target" "cost_guard" {
  rule = aws_cloudwatch_event_rule.cost_guard.name
  arn  = aws_lambda_function.cost_guard.arn
}

resource "aws_lambda_permission" "cost_guard_schedule" {
  statement_id  = "AllowCostGuardSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_guard.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost_guard.arn
}
