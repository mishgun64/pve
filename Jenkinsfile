pipeline {
    agent any

    triggers {
        GenericTrigger(
            genericVariables: [
                [key: 'EVENT', value: '$.event'],
                [key: 'PVE_NODE', value: '$.node'],
                [key: 'PVE_HOST', value: '$.host'],
                [key: 'ISO_VERSION', value: '$.version'],
                [key: 'LINUX_PATH', value: '$.linux'],
                [key: 'INITRD_PATH', value: '$.initrd']
            ],
            causeString: 'Triggered by webhook',
            token: 'pve-webhook',
            printContributedVariables: true,
            printPostContent: true
        )
    }

    environment {
        ANSIBLE_HOST_KEY_CHECKING = "False"
        ANSIBLE_REPO = "https://github.com/mishgun64/pve.git"
    }

    stages {

        stage('Run pve-first-boot playbook') {
            when {
                expression { env.EVENT == 'pve-first-boot' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - PVE-first-boot"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/pve_config_init.yml
                '''
            }
        }

        stage('Run pve-soft-config playbook') {
            when {
                expression { env.EVENT == 'pve-soft' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - PVE-soft-config"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/pve_config_soft.yml
                '''
            }
        }

        stage('pve-iso-get') {
            when {
                expression { env.EVENT == 'pve-iso-get' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - PVE-iso-get"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook ./ansible/control_node_update_iso.yml
                '''
            }
        }

        stage('terraform') {
            when {
                expression { env.EVENT == 'terraform' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Terraform"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    terraform -chdir=./terraform/ init -upgrade -var-file="prod.tfvars"
                    terraform -chdir=./terraform/ plan -var-file="prod.tfvars"
                    terraform -chdir=./terraform/ apply -var-file="prod.tfvars" -auto-approve
                '''
            }
        }

        stage('services') {
            when {
                expression { env.EVENT == 'services' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - API-token"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/api_token_test.yml
                '''
            }
        }

        stage('cloud-init-template') {
            when {
                expression { env.EVENT == 'cloud-init' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Cloud-init"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/cloud_init.yml
                '''
            }
        }

        stage('media_vm') {
            when {
                expression { env.EVENT == 'media_vm' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Media_vm-config"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/media_config.yml
                '''
            }
        }

        stage('media_vm_backup') {
            when {
                expression { env.EVENT == 'media_vm_backup' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Media_vm-backup"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/media_backup.yml
                '''
            }
        }
        stage('media_vm_restore') {
            when {
                expression { env.EVENT == 'media_vm_restore' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Media_vm-restore"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/media_restore.yml
                '''
            }
        }

        stage('known_hosts') {
            when {
                expression { env.EVENT == 'known_hosts' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Update-known_hosts"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/update_known_hosts_test.yml
                '''
            }
        }

        stage('wireguard') {
            when {
                expression { env.EVENT == 'wireguard' }
            }
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} - Wireguard"
                }
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/wireguard_server_config.yml
                '''
            }
        }
    }
}