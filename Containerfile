FROM registry.redhat.io/3scale-amp2/apicast-gateway-rhel8:3scale2.16.4

COPY reports_batcher.lua \
  /opt/app-root/src/src/apicast/policy/3scale_batcher/reports_batcher.lua
