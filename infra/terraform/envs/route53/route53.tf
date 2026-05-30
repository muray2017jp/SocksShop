data "aws_route53_zone" "jyouhou_net" {
  name         = "jyouhou.net."
  private_zone = false
}

resource "aws_route53_record" "sockshop" {
  zone_id = data.aws_route53_zone.jyouhou_net.zone_id
  name    = "sockshop.jyouhou.net"
  type    = "A"

  alias {
    name                   = data.aws_lb.sockshop.dns_name
    zone_id                = data.aws_lb.sockshop.zone_id
    evaluate_target_health = true
  }
}
