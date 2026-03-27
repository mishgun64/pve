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
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/pve_config_init_test.yml
                '''
            }
        }

        stage('pve-iso-get') {
            when {
                expression { env.EVENT == 'pve-iso-get' }
            }
            steps {
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
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/cloud_init_test.yml
                '''
            }
        }

        stage('media_vm') {
            when {
                expression { env.EVENT == 'media_vm' }
            }
            steps {
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
                git branch: 'main', url: "${ANSIBLE_REPO}"

                sh '''
                    ANSIBLE_CONFIG=./ansible/ansible.cfg ansible-playbook -i ./ansible/hosts_prod ./ansible/media_restore.yml
                '''
            }
        }
    }
}