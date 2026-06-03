obj-m := bmi2_emul.o

ARCH         := x86_64
CROSS_COMPILE := x86_64-pc-linux-gnu-
KSRC         ?= /opt/epyc7002/build

ccflags-y := -O2 -std=gnu11

all:
	$(MAKE) -C $(KSRC) M=$(PWD) \
		ARCH=$(ARCH) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		modules

clean:
	$(MAKE) -C $(KSRC) M=$(PWD) clean
