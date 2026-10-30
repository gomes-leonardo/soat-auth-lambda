output "auth_function_url" {
  description = "URL da autenticacao por CPF. O Kong roteia POST /auth/cpf para ela."
  value       = aws_lambda_function_url.auth_cpf.function_url
}

output "notifier_function_url" {
  description = "URL que o workflow de alertas do New Relic chama."
  value       = aws_lambda_function_url.notifier.function_url
}

output "alert_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
