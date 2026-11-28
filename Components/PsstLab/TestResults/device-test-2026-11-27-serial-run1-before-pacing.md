# psst-mesh device test 2026-11-27T16:20:08Z
PASS  connect over serial (/dev/cu.usbserial-0001), want_config → config_complete
my node: !bd460df0 (heltecV21), firmware 2.7.26.54e0d8d
region: eu868, preset longFast
channel 0 PRIMARY '(preset name)': default published key (AQ==)
channel 1 SECONDARY 'gechan': own key 256-bit
nodes (3 besides mine):
  !4572c052 ? []  last heard — snr -8.0 hops 0 pki no
  !ea251718 (T-LoRa V2.1-1.6) [geo] tloraV211P6 last heard — snr 9.5 hops 0 pki yes
  !7efeb300 (router) [GEOR] heltecV21 last heard — snr — hops — pki yes
PASS  my_info: own node number
PASS  LoRa region is set (eu868)
PASS  node DB contains other nodes (3)
target node: !ea251718
PASS  channel 0 broadcast: sent (packets 1, acked by node 0, relayed 1)
PASS  direct text to !ea251718 with ACK from the node: delivered (packets 1, acked by node 1, relayed 0)
PASS  psst E2E single-frame (47 B → 1 frame(s)) to !ea251718, all frames ACKed: delivered (packets 1, acked by node 1, relayed 0)
PASS  peer side reassembles + decrypts the single-frame message (same frames as sent)
FAIL  psst E2E chunked (490 B → 3 frame(s)) to !ea251718, all frames ACKed: failed("bez potvrdenia do 120 s") (packets 3, acked by node 1, relayed 0)
PASS  peer side reassembles + decrypts the chunked message (same frames as sent)
SKIP  receiving a psst E2E message over the air — the second radio has no psst lab client (see LAB-LORA.md)
result: 1 FAILED
