# Local LLM Infrastructure for Autonomous Software Development

## Objective

Build an autonomous software engineering agent capable of developing one product at a time **without paying per-token API costs** by self-hosting an open-source coding LLM.

---

# Existing Hardware

| Component | Specification |
|-----------|---------------|
| GPU | NVIDIA RTX 4090 (24 GB VRAM) |
| CPU | 48 Cores |
| Memory | 128 GB RAM |
| Storage | NVMe SSD (Recommended ≥2TB) |
| Development Style | Single Serial Autonomous Agent |

This workstation is already capable of running state-of-the-art open-source coding models.

---

# Recommended Open Source Models

## Primary Recommendation

### Qwen3-Coder 30B (4-bit Quantized)

Pros

- Excellent code generation
- Strong repository understanding
- Good debugging capability
- Excellent tool use
- Suitable for autonomous agents
- Fits comfortably on a 4090 using quantization

Expected Speed

- **25–35 tokens/sec**
- **1,500–2,100 tokens/min**

---

## Secondary Recommendation

### Devstral 24B

Pros

- Optimized specifically for software engineering
- Multi-file editing
- Repository refactoring
- Strong instruction following

Expected Speed

- **25–45 tokens/sec**
- **1,500–2,700 tokens/min**

---

## Alternative Models

| Model | Expected Speed |
|---------|---------------|
| Qwen3-Coder 14B | 45–80 tokens/sec |
| StarCoder2 15B | 40–70 tokens/sec |
| Llama 4 Scout (Quantized) | 15–30 tokens/sec |

---

# Models NOT Recommended for Local 4090

These require enterprise GPU clusters.

- DeepSeek V3
- DeepSeek R1 (Large)
- GPT-class dense models
- Claude-class models

These generally require

- 8×H100
- Multi-node clusters
- Hundreds of GB of VRAM

---

# Recommended Inference Engine

Instead of HuggingFace Transformers:

## Preferred

- vLLM

Advantages

- Continuous batching
- Much higher throughput
- Better KV cache
- Lower latency
- Production-ready API server

Alternative

- SGLang

Simpler alternative

- llama.cpp

---

# Expected Performance

## Qwen3-Coder 30B

Typical generation speed

25–35 tokens/sec

Examples

### Small function

500 tokens

≈20 seconds

---

### Medium implementation

1000 tokens

≈35–40 seconds

---

### Large refactor

2000 tokens

≈1–1.5 minutes

---

# Reality of Autonomous Coding

The LLM is **not** the bottleneck.

Typical development cycle:

```
Read repository
        │
   3–10 sec
        │
Generate code
        │
20–40 sec
        │
Run tests
        │
30 sec–5 min
        │
Analyze failures
        │
10–30 sec
        │
Generate fixes
        │
20–40 sec
```

Most time is spent:

- Compiling
- Testing
- Running Docker
- Executing tools
- Waiting for builds

The GPU is idle during much of this workflow.

---

# Cloud Comparison

## NVIDIA H100

Expected inference speed

| Hardware | Tokens/sec |
|----------|------------|
| RTX 4090 | 25–35 |
| H100 PCIe | 80–120 |
| H100 SXM | 120–180 |

Approximate improvement

- 3×–5× faster generation

---

# Cloud Cost

Typical rental prices

| Provider | Approximate Cost |
|-----------|-----------------:|
| Vast.ai | US$1.50–1.90/hr |
| RunPod | US$2.00–2.90/hr |
| Lambda Labs | ~US$2.50/hr |
| AWS/Azure/GCP | US$6–12+/hr |

Monthly (24×7)

| Hourly Cost | Monthly Cost |
|--------------|-------------:|
| US$1.50/hr | ~US$1,080 |
| US$2.50/hr | ~US$1,800 |
| US$3.00/hr | ~US$2,160 |

---

# Cost vs Performance

Local RTX4090

Pros

- Zero token cost
- One-time hardware investment
- Full privacy
- No rate limits
- Low operating cost

Cons

- Slower than H100
- Limited to approximately 30B models

---

Cloud H100

Pros

- 3–5× faster inference
- Can host much larger models
- Excellent for many concurrent agents

Cons

- US$1,000–2,000/month
- Ongoing operational cost
- Network latency
- Data leaves local machine

---

# Recommendation

Given the current workstation:

- RTX 4090
- 48-core CPU
- 128 GB RAM

**Do not rent an H100** for the initial implementation.

The local workstation is already well balanced for a **single autonomous software engineering agent**.

Recommended software stack:

```
Autonomous Coding Agent

            │
            ▼

    Qwen3-Coder 30B
       (4-bit)

            │

      vLLM Server

            │

      Agent Framework

            │

 Repository + Git

            │

 Docker + Tests

            │

 Build / Verify

            │

 Repeat Until Pass
```

---

# Future Scaling

Current Stage

- 1 serial coding agent
- Local RTX4090
- Qwen3-Coder 30B

Stage 2

- 3–5 concurrent agents
- Dual GPU workstation
- vLLM distributed serving

Stage 3

- 10+ concurrent agents
- H100 cluster
- DeepSeek-class models
- Multi-agent orchestration

---

# Final Recommendation

For the current project:

- **Hardware:** Existing workstation (RTX 4090 + 48-core CPU + 128 GB RAM)
- **Primary Model:** Qwen3-Coder 30B (4-bit quantized)
- **Secondary Model:** Devstral 24B
- **Inference Engine:** vLLM
- **Expected Throughput:** 25–35 tokens/sec
- **Development Style:** One autonomous coding agent operating serially
- **Cloud Requirement:** None initially
- **Estimated Monthly Token Cost:** US$0 (excluding electricity)