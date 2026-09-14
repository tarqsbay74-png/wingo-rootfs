# الأشياء المهمة الناقصة لـ Wine

---

## 🔴 **الحرجة فقط**

### **1. Audio Syscalls Verification**

**المشكلة:**
```bash
# ❌ Wine تحتاج الصوت
# ❌ لا يوجد check إن الـ syscalls موجودة
```

**الحل - أضف في build.sh بعد make install:**

```bash
echo "✓ Verifying Audio Syscalls..."
AUDIO_SYSCALLS=("socket" "sendmsg" "recvmsg" "mmap" "futex" "epoll_wait")
for sc in "${AUDIO_SYSCALLS[@]}"; do
    grep -q "__NR_${sc}" "$ROOTFS/include/asm/unistd.h" || {
        echo "❌ $sc missing" >&2
        exit 1
    }
done
```

---

### **2. Graphics Syscalls Verification**

**المشكلة:**
```bash
# ❌ Wine تحتاج الرسوميات
# ❌ لا يوجد check إن الـ syscalls موجودة
```

**الحل - أضف في build.sh:**

```bash
echo "✓ Verifying Graphics Syscalls..."
GRAPHICS_SYSCALLS=("mmap" "mprotect" "brk" "ioctl" "epoll_create")
for sc in "${GRAPHICS_SYSCALLS[@]}"; do
    grep -q "__NR_${sc}" "$ROOTFS/include/asm/unistd.h" || {
        echo "❌ $sc missing" >&2
        exit 1
    }
done
```

---

### **3. Wine Core Syscalls Verification**

**المشكلة:**
```bash
# ❌ بدون هذي syscalls = Wine لا تعمل أبداً
```

**الحل - أضف في build.sh:**

```bash
echo "✓ Verifying Wine Core Syscalls..."
WINE_SYSCALLS=("open" "read" "write" "clone" "futex" "execve" "socket" "mmap")
for sc in "${WINE_SYSCALLS[@]}"; do
    grep -q "__NR_${sc}" "$ROOTFS/include/asm/unistd.h" || {
        echo "❌ CRITICAL: $sc missing!" >&2
        exit 1
    }
done
```

---

### **4. Library Check**

**المشكلة:**
```bash
# ❌ قد تكون ليبات مهمة ناقصة
```

**الحل - أضف في build.sh:**

```bash
echo "✓ Checking Essential Libraries..."
for lib in libc libm libdl libpthread; do
    find "$ROOTFS/lib" -name "${lib}*" | grep -q . || {
        echo "❌ $lib missing" >&2
        exit 1
    }
done
```

---

## 🟡 **مهم لكن ليس critical**

### **5. TLS (Thread Local Storage)**

**المشكلة:**
```bash
# ⚠️ قد يؤثر على multi-threaded games
```

**الحل - أضف في build.sh:**

```bash
# في configure flags:
--enable-tls \  # أضف هذا
```

---

### **6. Compiler Optimization**

**المشكلة:**
```bash
# ⚠️ Flags ضعيفة = أداء بطيء
```

**الحل - عدّل في build.sh:**

```bash
# بدل:
# export CFLAGS="${CFLAGS:-} -O3 -march=armv8-a..."

# استخدم:
export CFLAGS="-O3 -march=armv8-a -mtune=cortex-a75 -fomit-frame-pointer"
export LDFLAGS="-Wl,-O1,--as-needed"
```

---

# ✅ الخلاصة: أضف هذا لـ build.sh

```bash
# قبل "echo DONE"، أضف:

echo ""
echo "🔍 Final Verification..."

# Audio
for sc in socket sendmsg recvmsg mmap futex epoll_wait; do
    grep -q "__NR_${sc}" "$ROOTFS/include/asm/unistd.h" || exit 1
done

# Graphics
for sc in mmap mprotect brk ioctl epoll_create; do
    grep -q "__NR_${sc}" "$ROOTFS/include/asm/unistd.h" || exit 1
done

# Wine Core
for sc in open read write clone futex execve socket mmap; do
    grep -q "__NR_${sc}" "$ROOTFS/include/asm/unistd.h" || exit 1
done

# Libraries
for lib in libc libm libdl libpthread; do
    find "$ROOTFS/lib" -name "${lib}*" | grep -q . || exit 1
done

echo "✅ All critical components verified"
```

---

