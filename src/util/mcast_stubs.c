#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>
#include <caml/fail.h>

CAMLprim value freetube_mcast_join(value v_fd, value v_group, value v_iface)
{
  CAMLparam3(v_fd, v_group, v_iface);
  struct ip_mreq mreq;
  memset(&mreq, 0, sizeof(mreq));
  mreq.imr_multiaddr.s_addr = inet_addr(String_val(v_group));
  mreq.imr_interface.s_addr = inet_addr(String_val(v_iface));
  int fd = Int_val(v_fd);
  if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0)
    caml_uerror("setsockopt(IP_ADD_MEMBERSHIP)", Nothing);
  CAMLreturn(Val_unit);
}
