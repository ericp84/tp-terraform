#!/bin/bash
# =====================================================
# script created assuming user is root
# this script is supposed to be run in in path /root/.ansible/terraform
# =====================================================
# SCRIPT DESCRIPTION
# This script automates the process of creating a secure Docker container,
# configuring it with Ansible, and pushing the resulting image to Docker Hub.
#
# STEPS:
# 1. Create the Dockerfile
# 2. Build the Docker image
# 3. Initialize Terraform
# 4. Apply Terraform configuration to create the container
# 5. Check running Docker containers and create an Ansible inventory
# 6. Initialize SSH packages in the container
# 7. Create the Ansible playbook and configure the container
# 8. Push the built image to Docker Hub
#
# NOTE:
# - Update the "global variables" section with the necessary information.
# - Ensure required dependencies (Terraform, Docker) are installed before running.
#
# =====================================================
export ANSIBLE_HOST_KEY_CHECKING=False
#---------- color for the output ----------#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
LIGHTBLUE='\033[0;94m'
LIGHTMAGENTA='\033[3;95m'
RESET='\033[0m'
#---------- global variables ----------#
container_name="ubuntu_terraform"
dockerhub_username="YOUR_DOCKERHUB_USERNAME"
dockerhub_password="YOUR_DOCKERHUB_TOKEN"
dockerhub_repository="secure_ubuntu"
playbook_file_path="/root/.ansible/playbook.yml"
inventory_file_path="/root/.ansible/inventory.yml"
ansiblecfg_file_path="/root/.ansible/ansible.cfg"
#---------- check existing package ----------#
if ! command -v terraform &> /dev/null; then
  echo "${RED}Terraform n'est pas installé. Veuillez l'installer avant de continuer.${RESET}"
  exit 1
fi

if ! command -v docker &> /dev/null; then
  echo "${RED}Docker n'est pas installé. Veuillez l'installer avant de continuer.${RESET}"
  exit 1
fi
#---------- script ----------#
echo -e "${LIGHTMAGENTA}Création du Dockerfile...${RESET}"
cat <<EOL > Dockerfile
FROM ubuntu:20.04

RUN apt-get update && apt-get install -y \
    nano \
    openssh-server \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
RUN echo 'root:rootpassword' | chpasswd

RUN mkdir ~/.ssh

EXPOSE 22
EOL
echo -e "${GREEN}Dockerfile déployé avec succès...${RESET}"
sleep 1

echo -e "${LIGHTMAGENTA}Construction de l'image...${RESET}"
docker build -t $container_name:latest .
sleep 1

echo -e "${LIGHTMAGENTA}Création du main.tf...${RESET}"
cat <<EOL > main.tf
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "2.16.0"
    }
  }
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}

resource "docker_image" "ubuntu_terraform" {
  name = "ubuntu_terraform:latest"
}

resource "docker_container" "ubuntu" {
  name  = "ubuntu_terraform"
  image = docker_image.ubuntu_terraform.latest
  must_run          = true
  publish_all_ports = true
  command = ["sleep", "3600"]
  privileged = true
}
EOL

echo -e "${GREEN}Le fichier main.tf a été créé avec succès...${RESET}"
sleep 1

echo -e "${LIGHTMAGENTA}Initialisation de Terraform...${RESET}"
terraform init
sleep 1

echo -e "${LIGHTMAGENTA}Application de la configuration Terraform pour créer un conteneur Docker...${RESET}"
terraform apply -auto-approve
sleep 1

echo -e "${YELLOW}Vérification des conteneurs Docker en cours d'exécution...${RESET}"
docker ps
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name")
port=$(docker port "$container_name" 22 | cut -d: -f2) 
sleep 1

echo -e "${YELLOW}Ajout de la configuration Ansible...${RESET}"
cat <<EOL > $ansiblecfg_file_path
[defaults]
action_warnings=False
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_cache
fact_caching_prefix=ansible_facts
remote_user=root
interpreter_python=auto_silent
system_warnings=False

[inventory]
enable_plugins = yaml, ini 
EOL

echo -e "${GREEN}Le fichier ansible.cfg a été mis à jour avec succès.${RESET}"
sleep 1

echo -e "${YELLOW}Ajout du port dans le fichier inventory.yml...${RESET}"
cat <<EOL > $inventory_file_path
groupe1:
  hosts:
    $container_name:
      ansible_host: 127.0.0.1
      ansible_port: $port
      ansible_user: root
EOL

echo -e "${GREEN}Le fichier inventory.yml a été mis à jour avec le port.${RESET}"
sleep 1
echo -e "$ip $container_name"| sudo tee -a /etc/hosts

echo -e "${LIGHTMAGENTA}Installation de la connexion SSH sur le conteneur...${RESET}"
docker cp ~/.ssh/id_rsa.pub $container_name:/root/.ssh/authorized_keys
sleep 1

echo -e "${LIGHTMAGENTA}Connexion et démarrage du service SSH dans le conteneur...${RESET}"
docker exec $container_name service ssh start

echo -e "${GREEN}Le conteneur Docker a été créé avec succès.${RESET}"
sleep 1

echo -e "${LIGHTMAGENTA}Déploiement du playbook.yml...${RESET}"
cat <<EOL > $playbook_file_path
- name: playbook secure host
  hosts: all
  remote_user: root
  tasks:
    - name: installation des paquets
      ansible.builtin.apt:
        name:
          - iptables
          - fail2ban
          - lynis
          - rkhunter
        state: present

    - name: Accepte les connexions ssh
      ansible.builtin.iptables:
        chain: INPUT
        protocol: tcp
        destination_port: 22
        source: 172.20.133.237/20
        jump: ACCEPT

    - name: Bloque ICMP
      ansible.builtin.iptables:
        chain: INPUT
        protocol: ICMP
        jump: DROP

    - name: Accept ICMP input
      ansible.builtin.iptables:
        chain: INPUT
        protocol: ICMP
        jump: ACCEPT

    - name: Autorise les connexions deja établie
      ansible.builtin.iptables:
        chain: INPUT
        ctstate: ESTABLISHED,RELATED
        jump: ACCEPT

    - name: Ajout des règles persistantes
      ansible.builtin.apt:
        name: iptables-persistent
        state: present

    - name: Ajout des règles en dur
      ansible.builtin.shell:
        cmd: iptables-save > /etc/iptables/rules.v4

    - name: Configurer Fail2Ban
      ansible.builtin.copy:
        dest: /etc/fail2ban/jail.local
        content: |
          [DEFAULT]
          bantime = 600
          findtime = 600
          maxretry = 3
          backend = systemd

          [sshd]
          enabled = true
          port = 22
          logpath = %(sshd_log)s
          maxretry = 3

    - name: Redémarrer Fail2Ban pour appliquer la configuration
      ansible.builtin.service:
        name: fail2ban
        state: restarted

    - name: Effectuer une analyse avec Lynis et enregistrer dans un fichier /tmp/lynis_audit.log
      ansible.builtin.shell:
        cmd: lynis audit system > /tmp/lynis_audit.log
EOL

echo -e "${GREEN}Le fichier playbook.yml a été créé avec succès...${RESET}"
sleep 1

echo -e "${LIGHTMAGENTA}Lancement de la configuration avec Ansible...${RESET}"
ansible-playbook -i $inventory_file_path $playbook_file_path
sleep 1

echo -e "${LIGHTMAGENTA}Connexion à Docker Hub...${RESET}"
docker login --username $dockerhub_username --password $dockerhub_password
sleep 1

echo -e "${YELLOW}Tag de l'image...${RESET}"
docker tag $container_name:latest $dockerhub_username/$dockerhub_repository:latest

echo -e "${LIGHTMAGENTA}Pousser l'image vers Docker Hub...${RESET}"
docker push $dockerhub_username/$dockerhub_repository:latest
sleep 1

echo -e "${GREEN}L'image a été poussée avec succès vers Docker Hub.${RESET}"
