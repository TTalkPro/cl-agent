# CL-Agent Examples

[中文](README.md) | English

This directory contains various usage examples for the CL-Agent framework.

---

## Directory Structure

### `mock/` - Mock Examples

**Purpose**: Testing and development using Mock

**Features**:
- No API key required
- Quick functionality testing
- Deterministic output

**Use Cases**:
- Unit testing
- Feature demonstration
- Development debugging

**How to Run**:
```lisp
;; Load Mock examples
(load "src/cl-agent/examples/mock/mock-usage.lisp")

;; Run all Mock examples
(run-mock-examples)

;; Run individual examples
(example-mock-quick-chat)
(example-mock-agent)
(example-mock-workflow)
```

**File List**:
- `mock-usage.lisp` - Basic Mock usage examples

---

### `real/` - Real API Examples

**Purpose**: Demonstrate how to use real LLM providers

**Features**:
- Connect to real APIs (ZhipuAI, OpenAI, etc.)
- Actual production environment usage

**Prerequisites**:
- Set `ZHIPU_API_KEY` environment variable (ZhipuAI)
- Set `OPENAI_API_KEY` environment variable (OpenAI)

**How to Run**:
```lisp
;; Load real API examples
(load "src/cl-agent/examples/real-usage.lisp")

;; Run all examples
(run-real-examples)

;; Run individual examples
(example-zhipu-basic)
(example-openai-basic)
(example-agent-with-zhipu)
```

**File List**:
- `real-usage.lisp` - ZhipuAI, OpenAI, Agent, workflow examples

---

### `basic/` - Basic Examples

**Purpose**: Framework basic functionality demonstration

**Includes**:
- Basic concept introduction
- Simple use cases
- API getting started

---

### `advanced/` - Advanced Examples

**Purpose**: Showcase advanced features and best practices

**Includes**:
- Checkpoints and state recovery
- Time-travel debugging
- Complex workflows
- RAG pipelines

---

## Running Recommendations

### 1. First Time Use

Start with Mock examples, quickly understand the framework without API keys:

```lisp
(load "src/cl-agent/examples/mock/mock-usage.lisp")
(run-mock-examples)
```

### 2. Real API Testing

After setting environment variables, run real API examples:

```bash
# Set environment variables
export ZHIPU_API_KEY="your-zhipu-api-key"
export OPENAI_API_KEY="your-openai-api-key"

# Run in Lisp
(load "src/cl-agent/examples/real-usage.lisp")
(run-real-examples)
```

### 3. Development and Testing

Use Mock examples for development, ensure logic is correct before switching to real APIs.

---

## Important Notes

### Mock vs Real API

| Feature | Mock | Real API |
|---------|------|----------|
| Requires API Key | No | Yes |
| Response Speed | Fast | Network dependent |
| Output Quality | Fixed patterns | Intelligent generation |
| Use Case | Testing/Demo | Production |

### No Fallback Strategy

This framework **will not** automatically fall back to Mock when real API fails:

- Clear distinction between test and production environments
- Avoid accidental API calls
- Clearer error diagnosis

**Error Handling**:

```lisp
(handler-case
    (let ((client (make-llm-client :provider real-provider)))
      ;; Real API call
      ...)
  (missing-api-key-error (c)
    (format t "Error: Missing API key~%")
    ;; Explicitly handle error, don't fall back to Mock
    ))
```

---

## Contribution Guidelines

When adding new examples:

1. **Choose appropriate directory**:
   - Mock testing → `mock/`
   - Real API calls → `real/`
   - Basic tutorials → `basic/`
   - Advanced usage → `advanced/`

2. **Follow naming conventions**:
   - File names: `xxx-usage.lisp` or `xxx-example.lisp`
   - Function names: `example-xxx` or `demo-xxx`

3. **Add comments**:
   - Purpose description at file header
   - Function docstrings
   - Key code line comments

4. **Update this document**:
   - Add new example description in corresponding section
   - Include how to run
