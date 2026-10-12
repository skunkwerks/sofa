import Config

# Sofa has no application config of its own. HTTP behaviour, including the
# IPv6-first dual stack transport options, is set per client via the
# `Req.new/1` options accepted by `Sofa.client/2`.
