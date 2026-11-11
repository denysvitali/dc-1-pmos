# Alpine package signing keys

These public keys are copied from Alpine's
[alpine-keys aports recipe](https://github.com/alpinelinux/aports/tree/master/main/alpine-keys)
for x86_64 and aarch64. They authenticate the bootstrap index and the installer
package repository; they are trust anchors, not package-version pins. When
Alpine rotates signing keys, verify new keys against Alpine's published sources
before adding them. Unknown keys fail closed.
