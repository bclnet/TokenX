/*
 * TokenX.kt
 * TokenX (Android)
 *
 * The one-call bootstrap: a server whose SQLite database sits in the app's
 * no-backup files directory and whose cipher key lives in the Android
 * Keystore. If either cannot be opened the server still comes up (in memory,
 * plain cipher) so the app keeps running.
 */
package com.bclnet.tokenx.android

import android.content.Context
import com.bclnet.tokenx.HttpTransport
import com.bclnet.tokenx.HttpUrlConnectionTransport
import com.bclnet.tokenx.InMemoryStore
import com.bclnet.tokenx.PlainCipher
import com.bclnet.tokenx.SecretCipher
import com.bclnet.tokenx.TokenServer
import com.bclnet.tokenx.TokenStore

object TokenX {
    /** A server in the app's private storage. `appId` names the Keystore alias so two apps sharing a process never share a key. */
    fun standard(context: Context, appId: String = context.packageName, transport: HttpTransport = HttpUrlConnectionTransport()): TokenServer {
        val app = context.applicationContext
        val store: TokenStore = runCatching { AndroidSqlDatabase.store(app) }.getOrElse { InMemoryStore() }
        val cipher: SecretCipher = runCatching { KeystoreCipher("$appId.tokenx") as SecretCipher }.getOrElse { PlainCipher }
        return TokenServer(store, cipher, transport)
    }
}
