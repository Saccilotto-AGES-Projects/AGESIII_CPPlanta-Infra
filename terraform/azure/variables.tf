variable "resource_group_name" {
  default = "cp-planta-ages"
}

variable "location" {
  description = "Azure region where resources will be created"
  default = "East US 2"
}

variable "vnet_name" {
  default = "cp-planta-vnet"
}

variable "address_space" {
  default = ["10.0.0.0/16"]
}

variable "subnet_name" {
  description = "Name of the subnet"
  type    = string
  default = "cp-planta-subnet"
}

variable "subnet_prefixes" {
  description = "Address prefixes for the subnet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "public_key_path" {
  default = "~/.ssh/id_rsa.pub"
}

variable "vm_names" {
  default = ["instance1", "instance2"]
}

variable "username" {
  default = "ubuntu"
}

variable "azure_subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}