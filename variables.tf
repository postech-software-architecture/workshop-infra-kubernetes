variable "region" {
  description = "Regiao AWS"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo de nomeacao dos recursos"
  type        = string
  default     = "workshop"
}

variable "cluster_version" {
  description = "Versao do control plane do EKS"
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "Tipos de instancia do managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Minimo de nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximo de nodes"
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes"
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas (workloads e RDS)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets publicas (NAT e NLB externo, se houver)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}
