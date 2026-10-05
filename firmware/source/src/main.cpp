/*
 * Chica Servo2040 USB Ethernet + serial firmware.
 *
 * Exposes the original Chica Servo2040 byte protocol over both:
 *   TCP 192.168.204.1:18712 (iOS)
 *   USB CDC-ACM             (Android)
 *
 * The frame format is intentionally unchanged from the USB CDC firmware:
 *   SET 0xD3 start count [low7 high7]...
 *   GET 0xC7 start count -> echoes header, then [low7 high7]...
 */

#include "bsp/board_api.h"
#include "tusb.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "dhserver.h"
#include "dnserver.h"
#include "lwip/ethip6.h"
#include "lwip/init.h"
#include "lwip/sys.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"

#include "main.h"

using namespace plasma;
using namespace servo;

#define INIT_IP4(a, b, c, d) \
  { PP_HTONL(LWIP_MAKEU32(a, b, c, d)) }

static constexpr uint16_t CHICA_HW_PORT = 18712;

const int START_PIN = servo2040::SERVO_1;
const int END_PIN = servo2040::SERVO_18;
const int NUM_SERVOS = (END_PIN - START_PIN) + 1;

ServoCluster servos = ServoCluster(pio0, 0, START_PIN, NUM_SERVOS);
Analog sen_adc = Analog(servo2040::SHARED_ADC);
Analog vol_adc = Analog(servo2040::SHARED_ADC, servo2040::VOLTAGE_GAIN);
Analog cur_adc = Analog(servo2040::SHARED_ADC, servo2040::CURRENT_GAIN,
                        servo2040::SHUNT_RESISTOR, servo2040::CURRENT_OFFSET);
AnalogMux mux = AnalogMux(servo2040::ADC_ADDR_0, servo2040::ADC_ADDR_1, servo2040::ADC_ADDR_2,
                          PIN_UNUSED, servo2040::SHARED_ADC);
WS2812 led_bar(servo2040::NUM_LEDS, pio1, 0, servo2040::LED_DATA);

uint servoEnabled = false;

static struct netif netif_data;
static uint32_t blink_interval_ms = 250;

uint8_t tud_network_mac_address[6] = {0x02, 0x02, 0x84, 0x6A, 0x96, 0x40};

static const ip4_addr_t ipaddr = INIT_IP4(192, 168, 204, 1);
static const ip4_addr_t netmask = INIT_IP4(255, 255, 255, 0);
static const ip4_addr_t gateway = INIT_IP4(0, 0, 0, 0);

static dhcp_entry_t entries[] = {
    {{0}, INIT_IP4(192, 168, 204, 2), 24 * 60 * 60},
    {{0}, INIT_IP4(192, 168, 204, 3), 24 * 60 * 60},
    {{0}, INIT_IP4(192, 168, 204, 4), 24 * 60 * 60},
};

static const dhcp_config_t dhcp_config = {
    .router = INIT_IP4(0, 0, 0, 0),
    .port = 67,
    .dns = INIT_IP4(192, 168, 204, 1),
    "usb",
    TU_ARRAY_SIZE(entries),
    entries
};

enum class ParsePhase {
  WaitingCommand,
  Start,
  Count,
  SetLow,
  SetHigh,
};

struct ChicaParser {
  ParsePhase phase = ParsePhase::WaitingCommand;
  uint8_t cmd = 0;
  uint start = 0;
  uint count = 0;
  uint valueIndex = 0;
  uint low7 = 0;
  uint values[MAX_COUNT_VALUE] = {0};
};

struct ChicaTcpClient {
  tcp_pcb *pcb = nullptr;
  ChicaParser parser;
};

using ReplyWriter = void (*)(void *context, const uint8_t *reply, uint length);

static ChicaParser cdc_parser;

uint cmdPin_to_hardwarePin(cmdPins cmdPin) {
  return RP_hardwarePins_table[cmdPin];
}

float read_current(void) {
  mux.select(servo2040::CURRENT_SENSE_ADDR);
  return cur_adc.read_current();
}

float read_voltage(void) {
  mux.select(servo2040::VOLTAGE_SENSE_ADDR);
  return vol_adc.read_voltage();
}

float read_analogPin(uint sensorAddress) {
  mux.select(sensorAddress);
  return sen_adc.read_voltage();
}

static void append_u14(uint8_t *reply, uint &offset, uint value) {
  reply[offset++] = value & 0x7F;
  reply[offset++] = (value >> 7) & 0x7F;
}

static void execute_set(const ChicaParser &parser) {
  uint pin = parser.start;
  for (uint idx = 0; idx < parser.count; idx++, pin++) {
    if (pin <= SERVO18) {
      servos.pulse(cmdPin_to_hardwarePin((cmdPins) pin), parser.values[idx], servoEnabled);
    } else if (pin >= RELAY && pin < cmdPin_num) {
      bool enableState = parser.values[idx] != 0;
      gpio_put(cmdPin_to_hardwarePin((cmdPins) pin), enableState);

      if (pin == RELAY) {
        servoEnabled = enableState;
        if (enableState) {
          servos.enable_all();
        } else {
          servos.disable_all();
        }
      }
    }
  }
}

static uint build_get_reply(const ChicaParser &parser, uint8_t *reply) {
  uint offset = 0;
  reply[offset++] = GET_CMD;
  reply[offset++] = parser.start;
  reply[offset++] = parser.count;

  uint pin = parser.start;
  for (uint idx = 0; idx < parser.count; idx++, pin++) {
    uint value = 0;
    if (pin <= SERVO18) {
      value = servos.pulse(cmdPin_to_hardwarePin((cmdPins) pin));
    } else if (pin <= TS6) {
      float sensorVoltage = read_analogPin(cmdPin_to_hardwarePin((cmdPins) pin));
      value = (uint) lroundf(sensorVoltage * b1024_3_3V_RATIO);
    } else if (pin == CURR) {
      float current = read_current();
      value = (uint) lroundf(current / CURR_LSb) + 512;
    } else if (pin == VOLT) {
      float voltage = read_voltage();
      value = (uint) lroundf(voltage * b1024_3_3V_RATIO);
    }
    append_u14(reply, offset, value);
  }

  return offset;
}

static void execute_get(const ChicaParser &parser, ReplyWriter writer, void *context) {
  uint8_t reply[3 + (MAX_COUNT_VALUE * 2)] = {0};
  uint length = build_get_reply(parser, reply);
  writer(context, reply, length);
}

static void tcp_reply_writer(void *context, const uint8_t *reply, uint length) {
  tcp_pcb *pcb = static_cast<tcp_pcb *>(context);
  if (pcb == nullptr) {
    return;
  }
  tcp_write(pcb, reply, length, TCP_WRITE_FLAG_COPY);
  tcp_output(pcb);
}

static void cdc_reply_writer(void *context, const uint8_t *reply, uint length) {
  (void) context;
  tud_cdc_write(reply, length);
  tud_cdc_write_flush();
}

static void parser_reset(ChicaParser &parser) {
  parser.phase = ParsePhase::WaitingCommand;
  parser.cmd = 0;
  parser.start = 0;
  parser.count = 0;
  parser.valueIndex = 0;
  parser.low7 = 0;
}

static void parser_feed(ChicaParser &parser, ReplyWriter writer, void *context, uint8_t byte) {
  switch (parser.phase) {
    case ParsePhase::WaitingCommand:
      if (byte == SET_CMD || byte == GET_CMD) {
        parser.cmd = byte;
        parser.phase = ParsePhase::Start;
      }
      break;

    case ParsePhase::Start:
      parser.start = byte;
      parser.phase = ParsePhase::Count;
      break;

    case ParsePhase::Count:
      parser.count = byte;
      if (parser.count > MAX_COUNT_VALUE || parser.start >= cmdPin_num ||
          parser.start + parser.count > cmdPin_num) {
        parser_reset(parser);
      } else if (parser.cmd == GET_CMD) {
        execute_get(parser, writer, context);
        parser_reset(parser);
      } else if (parser.count == 0) {
        parser_reset(parser);
      } else {
        parser.valueIndex = 0;
        parser.phase = ParsePhase::SetLow;
      }
      break;

    case ParsePhase::SetLow:
      parser.low7 = byte & 0x7F;
      parser.phase = ParsePhase::SetHigh;
      break;

    case ParsePhase::SetHigh:
      parser.values[parser.valueIndex++] = parser.low7 | ((byte & 0x7F) << 7);
      if (parser.valueIndex >= parser.count) {
        execute_set(parser);
        parser_reset(parser);
      } else {
        parser.phase = ParsePhase::SetLow;
      }
      break;
  }
}

static err_t tcp_client_close(ChicaTcpClient *client) {
  if (client == nullptr || client->pcb == nullptr) {
    delete client;
    return ERR_OK;
  }

  tcp_arg(client->pcb, nullptr);
  tcp_recv(client->pcb, nullptr);
  tcp_err(client->pcb, nullptr);
  tcp_poll(client->pcb, nullptr, 0);
  err_t err = tcp_close(client->pcb);
  if (err != ERR_OK) {
    tcp_abort(client->pcb);
  }
  client->pcb = nullptr;
  delete client;
  return ERR_OK;
}

static err_t chica_tcp_recv(void *arg, tcp_pcb *pcb, pbuf *p, err_t err) {
  ChicaTcpClient *client = (ChicaTcpClient *) arg;
  if (err != ERR_OK || p == nullptr) {
    if (p != nullptr) {
      pbuf_free(p);
    }
    return tcp_client_close(client);
  }

  tcp_recved(pcb, p->tot_len);
  for (pbuf *q = p; q != nullptr; q = q->next) {
    const uint8_t *bytes = (const uint8_t *) q->payload;
    for (uint16_t i = 0; i < q->len; i++) {
      parser_feed(client->parser, tcp_reply_writer, pcb, bytes[i]);
    }
  }
  pbuf_free(p);
  return ERR_OK;
}

static void chica_cdc_task(void) {
  uint8_t bytes[64];
  while (tud_cdc_available()) {
    uint32_t count = tud_cdc_read(bytes, sizeof(bytes));
    for (uint32_t i = 0; i < count; i++) {
      parser_feed(cdc_parser, cdc_reply_writer, nullptr, bytes[i]);
    }
  }
}

static void chica_tcp_err(void *arg, err_t err) {
  (void) err;
  ChicaTcpClient *client = (ChicaTcpClient *) arg;
  if (client != nullptr) {
    client->pcb = nullptr;
    delete client;
  }
}

static err_t chica_tcp_poll(void *arg, tcp_pcb *pcb) {
  (void) pcb;
  ChicaTcpClient *client = (ChicaTcpClient *) arg;
  if (client == nullptr) {
    return ERR_ABRT;
  }
  return ERR_OK;
}

static err_t chica_tcp_accept(void *arg, tcp_pcb *newpcb, err_t err) {
  (void) arg;
  if (err != ERR_OK || newpcb == nullptr) {
    return ERR_VAL;
  }

  ChicaTcpClient *client = new ChicaTcpClient();
  client->pcb = newpcb;
  tcp_arg(newpcb, client);
  tcp_recv(newpcb, chica_tcp_recv);
  tcp_err(newpcb, chica_tcp_err);
  tcp_poll(newpcb, chica_tcp_poll, 4);
  tcp_nagle_disable(newpcb);
  return ERR_OK;
}

static void init_chica_tcp_server(void) {
  tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
  if (pcb == nullptr) {
    printf("ERROR: failed to allocate Chica TCP PCB\n");
    return;
  }

  if (tcp_bind(pcb, IP_ADDR_ANY, CHICA_HW_PORT) != ERR_OK) {
    printf("ERROR: failed to bind Chica TCP port %u\n", CHICA_HW_PORT);
    tcp_abort(pcb);
    return;
  }

  pcb = tcp_listen(pcb);
  tcp_accept(pcb, chica_tcp_accept);
  printf("Chica Servo2040 hardware endpoint listening on 192.168.204.1:%u\n", CHICA_HW_PORT);
}

static err_t linkoutput_fn(struct netif *netif, struct pbuf *p) {
  (void) netif;

  for (;;) {
    if (!tud_ready()) {
      return ERR_USE;
    }
    if (tud_network_can_xmit(p->tot_len)) {
      tud_network_xmit(p, 0);
      return ERR_OK;
    }
    tud_task();
  }
}

static err_t ip4_output_fn(struct netif *netif, struct pbuf *p, const ip4_addr_t *addr) {
  return etharp_output(netif, p, addr);
}

static err_t netif_init_cb(struct netif *netif) {
  LWIP_ASSERT("netif != NULL", (netif != NULL));
  netif->mtu = CFG_TUD_NET_MTU;
  netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_LINK_UP | NETIF_FLAG_UP;
  netif->state = nullptr;
  netif->name[0] = 'C';
  netif->name[1] = 'S';
  netif->linkoutput = linkoutput_fn;
  netif->output = ip4_output_fn;
  return ERR_OK;
}

static void usbnet_netif_link_callback(struct netif *netif) {
  tud_network_link_state(BOARD_TUD_RHPORT, netif_is_link_up(netif));
}

static void init_lwip(void) {
  struct netif *netif = &netif_data;

  lwip_init();

  netif->hwaddr_len = sizeof(tud_network_mac_address);
  memcpy(netif->hwaddr, tud_network_mac_address, sizeof(tud_network_mac_address));
  netif->hwaddr[5] ^= 0x01;

  netif = netif_add(netif, &ipaddr, &netmask, &gateway, nullptr, netif_init_cb, ethernet_input);
  netif_set_default(netif);

#if LWIP_NETIF_LINK_CALLBACK
  netif_set_link_callback(netif, usbnet_netif_link_callback);
  netif_set_link_up(netif);
#else
  tud_network_link_state(BOARD_TUD_RHPORT, true);
#endif
}

static bool dns_query_proc(const char *name, ip4_addr_t *addr) {
  if ((strcmp(name, "servo2040.usb") == 0) || (strcmp(name, "chica.usb") == 0)) {
    *addr = ipaddr;
    return true;
  }
  return false;
}

extern "C" bool tud_network_recv_cb(const uint8_t *src, uint16_t size) {
  struct netif *netif = &netif_data;

  if (size) {
    struct pbuf *p = pbuf_alloc(PBUF_RAW, size, PBUF_POOL);
    if (p == nullptr) {
      return false;
    }

    pbuf_take(p, src, size);
    if (netif->input(p, netif) != ERR_OK) {
      pbuf_free(p);
    }
    tud_network_recv_renew();
  }

  return true;
}

extern "C" uint16_t tud_network_xmit_cb(uint8_t *dst, void *ref, uint16_t arg) {
  (void) arg;
  struct pbuf *p = (struct pbuf *) ref;
  return pbuf_copy_partial(p, dst, p->tot_len, 0);
}

static void init_servo2040_hardware(void) {
  servos.init();

  for (auto i = 0u; i < servo2040::NUM_SENSORS; i++) {
    mux.configure_pulls(servo2040::SENSOR_1_ADDR + i, false, true);
  }

  gpio_init_mask(A0_GPIO_MASK | A1_GPIO_MASK | A3_GPIO_MASK);
  gpio_set_dir_masked(A0_GPIO_MASK | A1_GPIO_MASK | A3_GPIO_MASK, GPIO_OUTPUT_MASK);
  gpio_put_masked(A0_GPIO_MASK | A1_GPIO_MASK | A3_GPIO_MASK, GPIO_LOW_MASK);

  led_bar.start();
  led_bar.clear();
}

static void led_blinking_task(void) {
  static uint32_t start_ms = 0;
  static bool led_state = false;

  if (tusb_time_millis_api() - start_ms < blink_interval_ms) {
    return;
  }
  start_ms += blink_interval_ms;

  board_led_write(led_state);
  led_state = !led_state;
}

int main(void) {
  board_init();

  tusb_rhport_init_t dev_init = {
      .role = TUSB_ROLE_DEVICE,
      .speed = TUSB_SPEED_AUTO
  };
  tusb_init(BOARD_TUD_RHPORT, &dev_init);
  board_init_after_tusb();

  init_servo2040_hardware();
  init_lwip();
  while (!netif_is_up(&netif_data)) {
    tud_task();
  }
  while (dhserv_init(&dhcp_config) != ERR_OK) {
    tud_task();
  }
  while (dnserv_init(IP_ADDR_ANY, 53, dns_query_proc) != ERR_OK) {
    tud_task();
  }
  init_chica_tcp_server();

  while (1) {
    tud_task();
    chica_cdc_task();
    sys_check_timeouts();
    led_blinking_task();
  }
}

extern "C" void tud_mount_cb(void) {
  blink_interval_ms = 1000;
}

extern "C" void tud_umount_cb(void) {
  blink_interval_ms = 250;
}

extern "C" void tud_suspend_cb(bool remote_wakeup_en) {
  (void) remote_wakeup_en;
  blink_interval_ms = 2500;
}

extern "C" void tud_resume_cb(void) {
  blink_interval_ms = tud_mounted() ? 1000 : 250;
}

extern "C" sys_prot_t sys_arch_protect(void) {
  return 0;
}

extern "C" void sys_arch_unprotect(sys_prot_t pval) {
  (void) pval;
}

extern "C" uint32_t sys_now(void) {
  return tusb_time_millis_api();
}
