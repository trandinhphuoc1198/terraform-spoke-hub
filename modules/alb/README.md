# Module: `alb`

Provisions an **internet-facing Application Load Balancer** that receives HTTP/HTTPS traffic and routes it to multiple Kubernetes applications running on worker nodes via the HTTPS NodePort. Each application gets its own target group with host-based routing. Worker nodes are registered dynamically through ASG attachments — no manual target management required.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_security_group` | `${env}-alb-sg` | Controls inbound HTTP (80) and HTTPS (443) traffic to the ALB |
| `aws_lb` | `${env}-k8s-alb` | Internet-facing ALB in the public subnets |
| `aws_lb_target_group` (×N) | `${env}-${app_name}-tg` | One per app; points to the worker HTTPS NodePort; includes per-app health checks |
| `aws_lb_listener` | — | HTTP :80 → redirects to HTTPS :443 |
| `aws_lb_listener` | — | HTTPS :443 → default action returns 404; listener rules forward to app target groups |
| `aws_lb_listener_rule` (×N) | — | One per app; routes by Host header to the matching target group |
| `aws_autoscaling_attachment` (×N) | — | One per app; keeps each target group in sync with the worker ASG |

---

## Traffic flow

```
Internet
   │
   ├─ TCP :80  ──────────────────┐
   │                              │
   ├─ TCP :443 (HTTPS)  ──────────┤
   │                              │
   ▼                              ▼
┌──────────────────────────────────────┐
│  ALB  (public subnets)               │
│  SG: 0.0.0.0/0 :80, :443            │
└──────────────────┬───────────────────┘
        HTTP       │  (→ HTTPS redirect)
                   │  
                   ▼  (HTTPS to worker HTTPS NodePort)
        ┌─ Host: app1.example.com ─→ app1-tg ─┐
        │                                      │
        ├─ Host: app2.example.com ─→ app2-tg ─┤  TCP :30443
        │                                      │  on worker SG
        └─ Unmatched hosts ─→ 404 response ────┘
                   │
                   ▼
┌──────────────────────────────────────┐
│  Worker nodes  (private subnets)     │
│  NGINX Ingress listens on :30443     │
│  Routes by Host header to apps       │
└──────────────────────────────────────┘
```

### ALB security group

| Direction | Source | Port | Reason |
|---|---|---|---|
| Ingress | `0.0.0.0/0` | TCP 80 | Public HTTP traffic (redirected to HTTPS) |
| Ingress | `0.0.0.0/0` | TCP 443 | Public HTTPS traffic |
| Egress | Worker SG | TCP `https_nodeport` (30443) | Forward to HTTPS NodePort on workers only |

The egress rule is scoped to the worker security group rather than `0.0.0.0/0`, limiting the ALB's blast radius.

---

## Health checks

Each target group has its own health check configuration, determined by the `apps` input variable:

| Setting | Value |
|---|---|
| Protocol | HTTPS (to match the target NodePort) |
| Path | Per-app (e.g. `/health`, `/api/health`) |
| Healthy threshold | 2 consecutive successes |
| Unhealthy threshold | 3 consecutive failures |
| Interval | 60 seconds |
| Timeout | 5 seconds |
| Matcher | 200–399 (any 2xx or 3xx response) |

Workers are only marked healthy for an app after the corresponding Kubernetes Ingress resource is serving that app and returning a successful status. This means the ALB will not route production traffic to a freshly joined worker until the application is actually ready.

The health path for each app is specified in the `apps` variable under the `health_path` key (required).

---

## Dynamic target registration

An `aws_autoscaling_attachment` binds the worker ASG to the target group. This means:

- When the ASG **scales out**, new instances are automatically registered.
- When the ASG **scales in**, terminating instances are automatically deregistered (after connection draining).

No lifecycle hooks or custom Lambda functions are needed.
HTTPS listener and certificate

If `var.certificate_arn` is provided, the HTTPS listener uses that ACM certificate. The listener rule conditions match on the `Host` header, allowing you to serve multiple apps (with different hostnames) from a single certificate (e.g., a wildcard cert like `*.example.com`).

HTTP traffic on port 80 is redirected to HTTPS (301) to enforce encryption.

---

## Host-based routing

Each app is identified by a hostname and priority:

```hcl
apps = {
  "app1" = {
    host        = "app1.example.com"
    health_path = "/health"
    priority    = 1
  }
  "app2" = {
    host        = "app2.example.com"
    health_path = "/api/v1/health"
    priority    = 2
  }
}
```

The ALB creates a listener rule for each app, matching on the Host header and forwarding to the corresponding target group. All target groups point to the same `https_nodeport` (30443) on the worker nodes. NGINX Ingress Controller (running in Kubernetes) then routes traffic within the cluster based on the Host header to the actual backing services.

---

## Variables

| Name | Type | Description |
|---|---|---|
| `env` | `string` | Environment name — prefix for resource names |
| `vpc_id` | `string` | VPC ID — used when creating the security group and target groups |
| `public_subnet_ids` | `list(string)` | Public subnets the ALB is spread across (for high availability) |
| `https_nodeport` | `number` | Kubernetes HTTPS NodePort the target groups forward to (default `30443`) |
| `worker_sg_id` | `string` | Worker security group ID — ALB egress is scoped to this SG |
| `asg_name` | `string` | Worker ASG name — used by `aws_autoscaling_attachment` for each app |
| `apps` | `map(object)` | Map of applications; each must have `host`, `health_path`, and `priority` keys |
| `certificate_arn` | `string` | ARN of an ACM certificate for the HTTPS listener (required for HTTPS) (for high availability) |
| `nodeport` | `number` | Kubernetes NodePort the target group forwards to (e.g. `30080`) |
| `worker_sg_id` | `string` | Worker security group ID — ALB egress is scoped to this SG |
| `asg_name` | `string` | Worker ASG name — used by `aws_autoscaling_attachment` |

---

## Outputs

| Name | Description |
|---|---|
| `alb_dns_name` | Public DNS name of the ALB — the entry point for all application traffic |
| `alb_sg_id` | ALB security group ID — passed to the `ec2` module so worker SG can allow inbound from the ALB |
