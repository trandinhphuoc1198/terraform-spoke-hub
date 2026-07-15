resource "aws_security_group" "alb" {
  name        = "${var.env}-alb-sg"
  description = "Allow HTTP/HTTPS inbound to ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP - redirected to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "HTTPS NodePort on worker nodes only"
    from_port       = var.https_nodeport
    to_port         = var.https_nodeport
    protocol        = "tcp"
    security_groups = [var.worker_sg_id]
  }

  tags = { Name = "${var.env}-alb-sg" }
}

resource "aws_lb" "main" {
  name               = "${var.env}-k8s-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = { Name = "${var.env}-k8s-alb", Env = var.env }
}

# One target group per app — all point to the same https_nodeport on workers.
# NGINX Ingress routes to the correct app based on the Host header.
# ALB does NOT verify the target TLS certificate, only the HTTP response code.
resource "aws_lb_target_group" "apps" {
  for_each = var.apps

  name        = "${var.env}-${each.key}-tg"
  port        = var.https_nodeport
  protocol    = "HTTPS"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = each.value.health_path
    port                = tostring(var.https_nodeport)
    protocol            = "HTTPS"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 60
    timeout             = 5
    matcher             = "200-399"
  }

  tags = { Name = "${var.env}-${each.key}-tg" }
}

resource "aws_autoscaling_attachment" "apps" {
  for_each = var.apps

  autoscaling_group_name = var.asg_name
  lb_target_group_arn    = aws_lb_target_group.apps[each.key].arn
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Default action returns 404 for any host not matched by a listener rule below.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# One listener rule per app — routes by Host header to the matching target group.
resource "aws_lb_listener_rule" "apps" {
  for_each = var.apps

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  condition {
    host_header {
      values = [each.value.host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apps[each.key].arn
  }
}
