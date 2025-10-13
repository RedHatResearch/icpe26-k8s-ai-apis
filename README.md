# Kubernetes Audio Transcription with Kueue and Whisper

This project demonstrates parallel audio transcription using OpenAI's Whisper model on Kubernetes/OpenShift, orchestrated by Kueue for workload management. It downloads audio files from the [Rev.com earnings22 speech dataset](https://github.com/revdotcom/speech-datasets/tree/main/earnings22/media) and transcribes them using either CPU or GPU.

## Quick Start

For experienced users, here's the TL;DR version:

```bash
# 1. Build and push containers
podman build -t quay.io/<user>/alpine:latest -f containers/init/Dockerfile containers/init/ && podman push quay.io/<user>/alpine:latest
podman build -t quay.io/<user>/whisper:latest -f containers/whisper/Dockerfile containers/whisper/ && podman push quay.io/<user>/whisper:latest

# 2. Create namespace and apply Kueue configs
oc create namespace sai
oc apply -f kueue/manifests/resource-flavor.yml
oc apply -f kueue/manifests/cluster-queue.yml
oc apply -f kueue/manifests/local-queue.yml

# 3. (Optional) Configure GitHub token
cp kueue/manifests/github-token-secret.yml.template kueue/manifests/github-token-secret.yml
# Edit github-token-secret.yml with your token, then:
oc apply -f kueue/manifests/github-token-secret.yml

# 4. Deploy ConfigMap and Job
oc apply -f kueue/manifests/download-script-configmap.yml
oc apply -f kueue/manifests/whisper-gpu.yml

# 5. Monitor
oc get workloads -n sai
oc get pods -n sai
```

See detailed instructions below for more information.

## Project Structure

```
.
├── containers/
│   ├── init/
│   │   └── Dockerfile          # Alpine image with curl and jq for downloading files
│   └── whisper/
│       └── Dockerfile          # Whisper transcription image with Python and ffmpeg
└── kueue/
    └── manifests/
        ├── resource-flavor.yml              # Defines CPU/GPU resource types
        ├── cluster-queue.yml                # Cluster-wide resource quota definitions
        ├── local-queue.yml                  # Namespace-scoped queue
        ├── download-script-configmap.yml    # Shell script for downloading audio files
        ├── whisper-gpu.yml                  # Main job manifest (indexed job)
        └── github-token-secret.yml.template # Template for GitHub API token
```

## Prerequisites

### Software Requirements
- OpenShift 4.19.4 cluster (or compatible Kubernetes cluster)
- Podman (for building containers)
- kubectl/oc CLI tools
- Kueue installed from [kubernetes-sigs/kueue](https://github.com/kubernetes-sigs/kueue)

### GPU Support Requirements (Optional)
For GPU-accelerated transcription, install the following operators on OpenShift:
1. **Node Feature Discovery (NFD) Operator** - Detects hardware features and labels nodes
2. **NVIDIA GPU Operator** - Manages NVIDIA GPU resources
3. Instantiate the ClusterPolicy CR after installing the GPU operator

## Setup Instructions

Follow these steps in order to set up the audio transcription pipeline:

### 1. Build and Push Container Images

**Build the init container** (Alpine with curl and jq for downloading audio files):
```bash
podman build -t quay.io/<your-username>/alpine:latest -f containers/init/Dockerfile containers/init/
podman push quay.io/<your-username>/alpine:latest
```

**Build the Whisper container** (Python with ffmpeg and openai-whisper for transcription):
```bash
podman build -t quay.io/<your-username>/whisper:latest -f containers/whisper/Dockerfile containers/whisper/
podman push quay.io/<your-username>/whisper:latest
```

### 2. Create Namespace

Create a dedicated namespace for your transcription workloads:
```bash
oc create namespace sai
```

### 3. Configure Kueue Resources

Apply Kueue configuration manifests **in this order**:

**Step 3.1: Resource Flavor** - Defines available resource types (CPU/GPU flavors):
```bash
oc apply -f kueue/manifests/resource-flavor.yml
```

**Step 3.2: Cluster Queue** - Defines resource quotas (6 CPUs, 8Gi memory, 2 GPUs):
```bash
oc apply -f kueue/manifests/cluster-queue.yml
```

**Step 3.3: Local Queue** - Namespace-scoped queue linked to the cluster queue:
```bash
oc apply -f kueue/manifests/local-queue.yml
```

### 4. Configure GitHub Access (Optional but Recommended)

The download script accesses GitHub's API. Without authentication, you're limited to 60 requests/hour. To avoid rate limiting:

**Step 4.1:** Generate a GitHub personal access token with `repo` scope at https://github.com/settings/tokens

**Step 4.2:** Create a secret file from the template:
```bash
# Copy the template
cp kueue/manifests/github-token-secret.yml.template kueue/manifests/github-token-secret.yml

# Edit the file and replace YOUR_GITHUB_TOKEN_HERE with your actual token
# IMPORTANT: Never commit github-token-secret.yml to version control!

# Apply the secret
oc apply -f kueue/manifests/github-token-secret.yml
```

**Security Note**: The file `kueue/manifests/github-token-secret.yml` is git-ignored to prevent accidentally committing your token.

### 5. Deploy the Download Script ConfigMap

The ConfigMap contains a shell script that:
- Fetches the list of MP3 files from the earnings22/media directory via GitHub API
- Uses the `JOB_COMPLETION_INDEX` environment variable to select which file to download
- Handles pagination for large directories (100 files per page)
- Implements retry logic with exponential backoff for rate limiting
- Downloads the selected audio file to `/data` directory using Git LFS media URLs

Apply the ConfigMap:
```bash
oc apply -f kueue/manifests/download-script-configmap.yml
```

## Running Transcription Jobs

### Step 6: Deploy and Monitor the Whisper Job

#### Understanding the Job Configuration

The job manifest (`kueue/manifests/whisper-gpu.yml`) uses an **Indexed Job** pattern for parallel processing:
- **Parallelism**: 2 pods run concurrently
- **Completions**: 6 total tasks (6 different audio files to process)
- **Completion Mode**: Indexed - each pod gets a unique `JOB_COMPLETION_INDEX` (0-5)

#### Job Architecture

**Init Container** (`download-audio`):
- Uses the Alpine image with curl and jq
- Mounts the download script from ConfigMap at `/scripts`
- Executes `download-audio.sh` which uses `JOB_COMPLETION_INDEX` to download a specific MP3 file
- Saves the audio file to shared `/data` volume
- Uses GitHub token from secret for API authentication (avoids rate limits)

**Main Container** (`whisper-transcriber`):
- Uses the Whisper image with Python, ffmpeg, and openai-whisper
- Reads the audio file from shared `/data` volume
- Runs Whisper transcription with the `tiny.en` model
- Outputs transcription to `/tmp`

#### Volume Configuration

| Volume Name | Type | Purpose | Mount Points |
|-------------|------|---------|--------------|
| `audio-data` | emptyDir | Shares downloaded audio between init and main containers | Init: `/data`, Main: `/data` |
| `model-cache-volume` | emptyDir | Caches Whisper model files to avoid re-downloading | Main: `/tmp/whisper_models` |
| `download-script` | configMap | Provides the download script to init container | Init: `/scripts` (executable) |

#### Deploy the Job

**Before deploying**, update the job manifest (`kueue/manifests/whisper-gpu.yml`) if needed:
- Change the namespace (default: `sai`)
- Update image references to match your container registry
- Adjust parallelism and completions values if desired

**Deploy the job**:
```bash
oc apply -f kueue/manifests/whisper-gpu.yml
```

#### Monitor Job Progress

Check Kueue workload status:
```bash
oc get workloads -n sai
```

View job status:
```bash
oc get jobs -n sai
oc describe job whisper-transcription-cpu -n sai
```

View running pods:
```bash
oc get pods -n sai
```

Check logs for a specific pod:
```bash
# View init container logs (download process)
oc logs <pod-name> -n sai -c download-audio

# View main container logs (transcription process)
oc logs <pod-name> -n sai -c whisper-transcriber
```

## How Indexed Jobs Work

Each pod in the job receives a unique `JOB_COMPLETION_INDEX` environment variable:
- Pod 1: `JOB_COMPLETION_INDEX=0` → downloads file at index 0
- Pod 2: `JOB_COMPLETION_INDEX=1` → downloads file at index 1
- ...and so on

This enables parallel processing of different files without coordination between pods. With parallelism=2, two files are processed simultaneously until all 6 completions are done.

## GPU vs CPU Configuration

The provided job uses CPU resources. To enable GPU transcription:

1. Ensure GPU operators are installed and nodes are labeled
2. Uncomment the GPU limits in `whisper-gpu.yml`:
```yaml
limits:
  nvidia.com/gpu: 1
```
3. Modify the Whisper command to use GPU acceleration (requires CUDA-compatible setup)

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                      Kueue ClusterQueue                     │
│                   (manages resource quotas)                 │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                   Kueue LocalQueue (sai)                    │
│              (namespace-scoped queue)                       │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│             Indexed Job (6 completions, 2 parallel)         │
├─────────────────────────────────────────────────────────────┤
│  Pod [0]                              Pod [1]               │
│  ┌────────────────┐                  ┌────────────────┐     │
│  │ Init: Download │ JOB_INDEX=0      │ Init: Download │ ... │
│  │ script+GitHub  │───────────▶file0 │ script+GitHub  │     │
│  └───────┬────────┘                  └───────┬────────┘     │
│          │ /data (emptyDir)                  │              │
│          ▼                                   ▼              │
│  ┌────────────────┐                  ┌────────────────┐     │
│  │ Main: Whisper  │                  │ Main: Whisper  │     │
│  │ transcription  │                  │ transcription  │     │
│  └────────────────┘                  └────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

## Dataset Information

Audio files are sourced from the [Rev.com Speech Datasets - earnings22](https://github.com/revdotcom/speech-datasets/tree/main/earnings22/media) collection, which contains earnings call recordings in MP3 format. The download script automatically filters for `.mp3` files and handles GitHub's pagination to support large directories.

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| **GitHub rate limit errors** | Ensure the GitHub token secret is properly configured (Step 4) |
| **Pod failures during download** | Check init container logs: `oc logs <pod-name> -n sai -c download-audio` |
| **GPU not detected** | Verify NFD and GPU operators are running: `oc get pods -n nvidia-gpu-operator` and ensure nodes have GPU labels: `oc get nodes --show-labels \| grep nvidia` |
| **Job stuck in queue** | Check Kueue workload admission status: `oc describe workload <name> -n sai` |
| **Image pull errors** | Verify container images are pushed to your registry and image references in manifests are correct |
| **Transcription fails** | Check main container logs: `oc logs <pod-name> -n sai -c whisper-transcriber` |
