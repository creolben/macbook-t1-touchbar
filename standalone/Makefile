# Build ONLY the three T1 Touch Bar modules.
#
# applespi is deliberately excluded: the in-tree applespi already drives the
# keyboard and touchpad, and building this out-of-tree copy would shadow it.
# Only apple-ibridge / apple-ib-tb / apple-ib-als are missing from mainline.

obj-m += apple-ibridge.o
obj-m += apple-ib-tb.o
obj-m += apple-ib-als.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
