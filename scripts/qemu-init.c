/* Minimal static /init for the QEMU smoke test: report that userspace was
 * reached, then power off (PSCI SYSTEM_OFF makes QEMU exit). */
#include <fcntl.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

static const char marker[] = "J7CI-INIT-REACHED\n";

static void say(const char *path)
{
	int fd = open(path, O_WRONLY | O_NOCTTY);
	if (fd >= 0) {
		write(fd, marker, sizeof(marker) - 1);
		close(fd);
	}
}

int main(void)
{
	mkdir("/dev", 0755);
	mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
	write(1, marker, sizeof(marker) - 1);
	say("/dev/kmsg");
	say("/dev/console");
	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
}
