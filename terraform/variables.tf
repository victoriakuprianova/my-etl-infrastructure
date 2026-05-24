variable "yc_token" {
  description = "OAuth-токен для доступа к Yandex Cloud"
  type        = string
  sensitive   = true
}

variable "cloud_id" {
  description = "ID облака"
  type        = string
}

variable "folder_id" {
  description = "ID папки"
  type        = string
}

variable "zone" {
  description = "Зона доступности"
  type        = string
  default     = "ru-central1-a"
}