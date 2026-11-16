/* Minimal static /init for the QEMU smoke test. The marker is stored reversed and
 * built at run time, so the forward string exists in guest RAM only if this code
 * ran. It is written to /dev/kmsg (kernel log) and to the console, then the guest
 * powers off (PSCI SYSTEM_OFF). */
#include <fcntl.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

static const char rev[] = "\nDEHCAER-TINI-IC7J";
static char marker[sizeof(rev)];

static void say(const char *path)
{
	int fd = open(path, O_WRONLY | O_NOCTTY);
	if (fd >= 0) {
		if (write(fd, marker, sizeof(rev) - 1) < 0)
			;
		close(fd);
	}
}

int main(void)
{
	for (size_t i = 0; i < sizeof(rev) - 1; i++)
		marker[i] = rev[sizeof(rev) - 2 - i];
	mkdir("/dev", 0755);
	mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
	if (write(1, marker, sizeof(rev) - 1) < 0)
		;
	say("/dev/kmsg");
	say("/dev/console");
	sync();
	sleep(1);
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
}
