package com.coucou.android.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import com.coucou.android.R
import java.net.URL
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject

/**
 * Nyeko keeps itself up to date like the user's other apps: the Actions "Release Nyeko" workflow publishes each build in a GitHub
 * Release (Nyeko.apk and nyeko-android.json: build number, SHA-256), and the Nyeko site (phone/web/_worker.js) serves the
 * newest one at /downloads/android (a redirect to the file on GitHub) and /downloads/android.json. The app looks at
 * most every few hours (when it opens, and from the keep-alive alarm), downloads a newer build, checks its SHA-256 and hands it
 * to Android's own installer.
 *
 * Android only installs an update signed with the same key as the app already installed, so nothing else can be pushed this
 * way. The first update asks the user to confirm (a notification when the app is in the background); once Nyeko has installed
 * itself, later updates install without a question on Android 12 and later.
 */
object NyekoUpdater {
    /** Where the web app (and so the APK) is published: phone/web, deployed to Cloudflare Pages. */
    const val SITE = "https://nyeko-phone.pages.dev"
    private const val CHECK_EVERY_MS = 6 * 60 * 60 * 1000L
    private const val TAG = "CoucouLaunch" // a tag the release build already checks is gone (build.gradle.kts)
    private const val CHANNEL = "nyeko_updates"

    data class Release(val versionCode: Long, val versionName: String, val sha256: String, val size: Long)

    /** The app is on screen: the installer's question can be shown at once instead of as a notification. */
    @Volatile var appInFront = false
    @Volatile private var busy = false

    fun parse(json: String): Release? = try {
        val o = JSONObject(json)
        val sha = o.getString("sha256").lowercase()
        if (sha.length != 64 || !sha.all { it in '0'..'9' || it in 'a'..'f' }) null
        else Release(o.getLong("versionCode"), o.optString("versionName").take(32), sha, o.optLong("size"))
    } catch (_: Exception) {
        null
    }

    fun installedVersion(context: Context): Long =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode }.getOrDefault(Long.MAX_VALUE)

    fun installedName(context: Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty()

    /** Looks for a newer build, at most every few hours ([force]: now), and installs it. Never on the main thread. */
    fun maybeUpdate(context: Context, force: Boolean = false, onResult: (String) -> Unit = {}) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences("coucou_ui", Context.MODE_PRIVATE)
        val last = prefs.getLong("nyeko_update_checked", 0)
        if (!force && System.currentTimeMillis() - last < CHECK_EVERY_MS) return
        if (busy) return
        busy = true
        Thread({
            try {
                prefs.edit().putLong("nyeko_update_checked", System.currentTimeMillis()).apply()
                val r = check(app)
                when {
                    r == null -> onResult("Nyeko is up to date.")
                    else -> onResult(install(app, r) ?: "Installing Nyeko ${r.versionName}…")
                }
            } catch (e: Exception) {
                Log.d(TAG, "update: ${e.javaClass.simpleName}")
                onResult("Couldn't look for an update.")
            } finally {
                busy = false
            }
        }, "nyeko-update").apply { isDaemon = true; start() }
    }

    /** The newer build on the site, or null. Blocking. */
    private fun check(context: Context): Release? {
        val c = URL("$SITE/downloads/android.json").openConnection() as HttpsURLConnection
        c.connectTimeout = 10_000
        c.readTimeout = 10_000
        c.useCaches = false
        return try {
            if (c.responseCode != 200) null
            else parse(c.inputStream.bufferedReader().use { it.readText().take(4096) })
                ?.takeIf { it.versionCode > installedVersion(context) }
        } finally {
            c.disconnect()
        }
    }

    /** Downloads the build, checks it, and starts Android's installer. Null when started, else why not. Blocking. */
    private fun install(context: Context, r: Release): String? {
        val c = URL("$SITE/downloads/android").openConnection() as HttpsURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        c.useCaches = false
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            if (r.size > 0) setSize(r.size)
            // Once Nyeko installed itself, Android 12+ lets it update itself without asking again.
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        val session = installer.openSession(id)
        try {
            if (c.responseCode != 200) { session.abandon(); return "The update could not be downloaded." }
            val digest = MessageDigest.getInstance("SHA-256")
            c.inputStream.use { input ->
                session.openWrite("nyeko.apk", 0, if (r.size > 0) r.size else -1).use { out ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > 200L * 1024 * 1024) throw IllegalStateException("too large")
                        digest.update(buf, 0, n)
                        out.write(buf, 0, n)
                    }
                    session.fsync(out)
                }
            }
            val got = digest.digest().joinToString("") { "%02x".format(it) }
            if (got != r.sha256) { session.abandon(); return "The update did not match its checksum: not installed." }
            val status = PendingIntent.getBroadcast(
                context, 7, Intent(context, NyekoUpdateReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(status.intentSender)
            return null
        } catch (e: Exception) {
            runCatching { session.abandon() }
            throw e
        } finally {
            session.close()
            c.disconnect()
        }
    }

    /** Android wants the user to confirm, and the app is in the background: a notification opens the question. */
    fun notifyReady(context: Context, confirm: Intent) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Nyeko updates", NotificationManager.IMPORTANCE_DEFAULT))
        val tap = PendingIntent.getActivity(context, 8, confirm, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_mochi)
            .setContentTitle("A Nyeko update is ready")
            .setContentText("Tap to install it.")
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        runCatching { nm.notify(CHANNEL.hashCode(), n) }
    }
}

/** Not exported: only Android's installer, through our own PendingIntent, sends to it. */
class NyekoUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                confirm ?: return
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (NyekoUpdater.appInFront) runCatching { context.startActivity(confirm) }.onFailure { NyekoUpdater.notifyReady(context, confirm) }
                else NyekoUpdater.notifyReady(context, confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> Unit // Android restarts the app with the new build
            else -> Log.d("CoucouLaunch", "update not installed: ${intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)}")
        }
    }
}
