// P16 proof pipeline — lives in the throwaway `p16-proof` GitHub repo.
//
// This is NOT a product pipeline (those are P17/P18/P19). Its only job is to PROVE the six things the
// P16 "done means" requires, end to end on the graded controller:
//   1. a GitHub webhook/SCM event triggers the build (Source)
//   2. the box authenticates to AWS via the EC2 INSTANCE ROLE — no static keys anywhere
//   3. Jenkins reads a modelmatch-jenkins-* secret via the AWS Secrets Manager Credentials Provider
//   4. the box pushes an image to ECR using the instance role
//   5. the box writes to the gitops repo using the WRITE deploy key (a separate identity)
//   6. the box invokes Bedrock Nova (the e2e-live permission P18 will use)
//
// Credentials are referenced by ID only (the Secrets Manager secret NAME) — never plaintext.

pipeline {
  agent any

  environment {
    AWS_DEFAULT_REGION = 'ap-south-1'
    ECR_REGISTRY       = '832285994273.dkr.ecr.ap-south-1.amazonaws.com'
    ECR_REPO           = 'modelmatch-backend'                 // push a throwaway tag here (operator cleans up)
    INSTANCE_ROLE      = 'modelmatch-jenkins-role'            // what aws sts must show
    NOVA_MODEL_ID      = 'apac.amazon.nova-lite-v1:0'         // the APAC Nova Lite inference profile
    GITOPS_REPO        = 'git@github.com:Steve-droid/modelmatch-gitops.git'
    // credential IDs == the Secrets Manager secret names (flat, slash-free — plugin requirement)
    CRED_HMAC          = 'modelmatch-jenkins-p16-proof-webhook-hmac' // THROWAWAY proof-only secret
    CRED_GITOPS_KEY    = 'modelmatch-jenkins-gitops-deploy-key'      // PERSISTENT (P17/P18 reuse)
  }

  stages {
    stage('1. Source (webhook → build)') {
      steps {
        checkout scm
        sh 'echo "Triggered build: ${BUILD_TAG}"; git --no-pager log -1 --oneline'
      }
    }

    stage('2. AWS auth via instance role (no static keys)') {
      steps {
        sh '''
          set -eu
          # No static AWS key env vars may be present — the instance profile is the only identity.
          if [ -n "${AWS_ACCESS_KEY_ID:-}" ] || [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
            echo "FAIL: static AWS credentials are set in the environment"; exit 1
          fi
          ARN="$(aws sts get-caller-identity --query Arn --output text)"
          echo "Caller: $ARN"
          echo "$ARN" | grep -q ":assumed-role/${INSTANCE_ROLE}/" \
            || { echo "FAIL: not the ${INSTANCE_ROLE} instance role"; exit 1; }
          echo "OK: authenticated as the instance role, no static keys"
        '''
      }
    }

    stage('3. Read a modelmatch-jenkins-* secret via the plugin') {
      steps {
        withCredentials([string(credentialsId: env.CRED_HMAC, variable: 'HMAC')]) {
          sh '''
            set -eu
            [ -n "$HMAC" ] || { echo "FAIL: webhook HMAC empty"; exit 1; }
            echo "OK: read the webhook HMAC via the Credentials Provider (length ${#HMAC})"
          '''
        }
      }
    }

    stage('4. Push a throwaway image to ECR (instance role)') {
      steps {
        sh '''
          set -eu
          TAG="p16-proof-${BUILD_NUMBER}"
          aws ecr get-login-password --region "$AWS_DEFAULT_REGION" \
            | docker login --username AWS --password-stdin "$ECR_REGISTRY"
          # tiny image from ECR Public (no Docker Hub auth / rate limit)
          printf 'FROM public.ecr.aws/docker/library/busybox:latest\\nRUN true\\n' > Dockerfile.p16
          docker build -f Dockerfile.p16 -t "$ECR_REGISTRY/$ECR_REPO:$TAG" .
          docker push "$ECR_REGISTRY/$ECR_REPO:$TAG"
          echo "OK: pushed $ECR_REPO:$TAG via the instance role"
          # The proof proves PUSH only. The instance role intentionally has NO ecr:BatchDeleteImage,
          # so the throwaway tag is removed by an operator (runbook) / the ECR lifecycle policy — not here.
        '''
      }
    }

    stage('5. Write to gitops via the deploy key') {
      steps {
        // Standard ModelMatch SSH pattern: withCredentials + sshUserPrivateKey (NOT the SSH Agent
        // plugin, which is "up for adoption"). Bind the key to a temp file, pass it via GIT_SSH_COMMAND.
        withCredentials([sshUserPrivateKey(credentialsId: env.CRED_GITOPS_KEY,
                                           keyFileVariable: 'GITOPS_KEY',
                                           usernameVariable: 'GITOPS_USER')]) {
          sh '''
            set -eu
            export GIT_SSH_COMMAND="ssh -i $GITOPS_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
            rm -rf gitops-proof
            git clone "$GITOPS_REPO" gitops-proof
            cd gitops-proof
            git config user.email "jenkins@modelmatch.ci"
            git config user.name  "modelmatch-jenkins"
            mkdir -p ci-proof
            echo "P16 proof build ${BUILD_NUMBER} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > ci-proof/p16-proof.txt
            git add ci-proof/p16-proof.txt
            git commit -m "ci: P16 deploy-key write proof (build ${BUILD_NUMBER})"
            # push to a throwaway branch — proves WRITE access without touching main or ArgoCD
            git push --force origin HEAD:ci/p16-proof
            echo "OK: wrote to gitops via the deploy key (branch ci/p16-proof)"
          '''
        }
      }
    }

    stage('6. Bedrock InvokeModel (e2e-live permission)') {
      steps {
        sh '''
          set -eu
          OUT="$(aws bedrock-runtime converse \
            --region "$AWS_DEFAULT_REGION" \
            --model-id "$NOVA_MODEL_ID" \
            --messages '[{"role":"user","content":[{"text":"Reply with the single word: ok"}]}]' \
            --inference-config '{"maxTokens":5}' \
            --query 'output.message.content[0].text' --output text)"
          echo "Bedrock Nova replied: $OUT"
          [ -n "$OUT" ] || { echo "FAIL: empty Bedrock response"; exit 1; }
          echo "OK: bedrock:InvokeModel works via the instance role"
        '''
      }
    }
  }

  post {
    success { echo 'P16 PROOF GREEN — all six controller capabilities verified.' }
  }
}
