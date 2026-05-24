terraform {
  required_version = ">= 0.13"
  required_providers {
    yandex = { source = "yandex-cloud/yandex" }
  }
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

# --- 1. СЕТЬ ---
resource "yandex_vpc_network" "etl_net" { name = "etl-network" }

resource "yandex_vpc_subnet" "subnet_a" {
  name           = "subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.etl_net.id
  v4_cidr_blocks = ["10.1.0.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "subnet_b" {
  name           = "subnet-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.etl_net.id
  v4_cidr_blocks = ["10.2.0.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_gateway" "nat_gateway" {
  name = "etl-nat-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rt" {
  name       = "etl-route-table"
  network_id = yandex_vpc_network.etl_net.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

# --- 2. ГРУППА БЕЗОПАСНОСТИ ---
resource "yandex_vpc_security_group" "k8s_sg" {
  name       = "k8s-security-group"
  network_id = yandex_vpc_network.etl_net.id

  ingress {
    protocol       = "TCP"
    description    = "Доступ к API из интернета"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  ingress {
    protocol       = "TCP"
    description    = "SSH для Jump-хоста"
    v4_cidr_blocks = ["0.0.0.0/0"] 
    port           = 22
  }

  ingress {
    protocol       = "ANY"
    description    = "Связь внутри всей приватной сети (Pod-to-Pod + Jump-to-Master + DB-routing)"
    v4_cidr_blocks = ["10.0.0.0/8"] 
    from_port      = 0
    to_port        = 65535
  }

  ingress {
    protocol          = "ANY"
    description       = "Связь внутри группы"
    predefined_target = "self_security_group"
    from_port         = 0
    to_port           = 65535
  }

  ingress {
    protocol          = "TCP"
    description       = "Правило для работы балансировщиков"
    predefined_target = "loadbalancer_healthchecks"
    from_port         = 0
    to_port           = 65535
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# --- 3. ЕДИНЫЙ СЕРВИСНЫЙ АККАУНТ ---
resource "yandex_iam_service_account" "sa" { name = "etl-sa-prod" }

resource "yandex_resourcemanager_folder_iam_member" "sa_roles" {
  for_each = toset([
    "k8s.clusters.agent",
    "k8s.viewer",
    "container-registry.images.puller",
    "storage.editor",
    "vpc.publicAdmin",
    "logging.writer"
  ])
  folder_id = var.folder_id
  role      = each.key
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa_key" {
  service_account_id = yandex_iam_service_account.sa.id
}

# --- 4. KUBERNETES КЛАСТЕР ---
resource "yandex_kubernetes_cluster" "k8s" {
  name       = "etl-cluster"
  network_id = yandex_vpc_network.etl_net.id
  
  # Автоматический выбор дефолтной стабильной версии Яндекса
  release_channel = "STABLE"

  master {
    zonal {
      zone      = yandex_vpc_subnet.subnet_a.zone
      subnet_id = yandex_vpc_subnet.subnet_a.id
    }
    public_ip          = true
    security_group_ids = [yandex_vpc_security_group.k8s_sg.id]
  }
  service_account_id      = yandex_iam_service_account.sa.id
  node_service_account_id = yandex_iam_service_account.sa.id
  depends_on              = [yandex_resourcemanager_folder_iam_member.sa_roles]
}

resource "yandex_kubernetes_node_group" "nodes" {
  cluster_id = yandex_kubernetes_cluster.k8s.id
  name       = "spark-nodes-autoscale"

  instance_template {
    platform_id = "standard-v3"
    resources { 
      cores  = 4
      memory = 16 
    }
    boot_disk { 
      type = "network-ssd"
      size = 100 
    }
    network_interface {
      subnet_ids         = [yandex_vpc_subnet.subnet_a.id]
      nat                = false
      security_group_ids = [yandex_vpc_security_group.k8s_sg.id]
    }
  }
  scale_policy {
    auto_scale { 
      min     = 1 
      max     = 5
      initial = 1 
    }
  }
}

# --- 5. JUMP-ХОСТ (БАСТИОН) ---
resource "yandex_compute_instance" "jump_host" {
  name        = "jump-host"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id 
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet_a.id
    nat       = true 
    security_group_ids = [yandex_vpc_security_group.k8s_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("${path.module}/key.txt.pub")}"
  }

  scheduling_policy {
    preemptible = true 
  }
}

# --- 6. POSTGRESQL ---
resource "yandex_mdb_postgresql_cluster" "db" {
  name        = "airflow-db"
  environment = "PRODUCTION"
  network_id  = yandex_vpc_network.etl_net.id
  security_group_ids = [yandex_vpc_security_group.k8s_sg.id]
  config {
    version = 15
    resources {
      resource_preset_id = "s3-c2-m8"
      disk_type_id       = "network-ssd"
      disk_size          = 20
    }
  }
  host { 
    zone      = "ru-central1-a"
    subnet_id = yandex_vpc_subnet.subnet_a.id 
  }
  host { 
    zone      = "ru-central1-b" 
    subnet_id = yandex_vpc_subnet.subnet_b.id 
  }
}

resource "yandex_mdb_postgresql_user" "u" {
  cluster_id = yandex_mdb_postgresql_cluster.db.id
  name       = "airflow"
  password   = "securepassword123"
}

resource "yandex_mdb_postgresql_database" "db_airflow" {
  cluster_id = yandex_mdb_postgresql_cluster.db.id
  name       = "airflow"
  owner      = yandex_mdb_postgresql_user.u.name
}

# --- 7. ХРАНИЛИЩЕ И РЕЕСТР ---
resource "yandex_container_registry" "reg" { name = "etl-registry" }

resource "yandex_storage_bucket" "logs" {
  bucket     = "airflow-logs-${var.folder_id}"
  access_key = yandex_iam_service_account_static_access_key.sa_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_key.secret_key
  depends_on = [yandex_resourcemanager_folder_iam_member.sa_roles]
}

# OUTPUTS
output "cluster_id" { value = yandex_kubernetes_cluster.k8s.id }
output "jump_host_ip" { value = yandex_compute_instance.jump_host.network_interface.0.nat_ip_address }

data "yandex_compute_image" "ubuntu_2204" {
  family = "ubuntu-2204-lts"
}
