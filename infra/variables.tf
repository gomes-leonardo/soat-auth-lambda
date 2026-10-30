variable "environment" {
  description = "Ambiente: hml (branch develop) ou prd (branch main)."
  type        = string

  validation {
    condition     = contains(["hml", "prd"], var.environment)
    error_message = "environment deve ser hml ou prd."
  }
}

variable "region" {
  description = "Regiao AWS. Lambda, SNS e SSM ficam no Always Free em qualquer regiao."
  type        = string
  default     = "sa-east-1"
}

variable "alert_email" {
  description = "E-mail que recebe os alertas. A assinatura SNS precisa ser confirmada pelo link que chega nele."
  type        = string
}

variable "dist_dir" {
  description = "Onde o `npm run build` deixou os bundles."
  type        = string
  default     = "../dist"
}
