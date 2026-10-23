package com.fluxshare.network

import android.util.Log

internal object SafeLog {
    const val NETWORK = "FluxShare/Network"
    const val DISCOVERY = "FluxShare/Discovery"
    const val SERVER = "FluxShare/Server"
    const val PEER = "FluxShare/Peer"
    const val MANIFEST = "FluxShare/Manifest"
    const val TRANSFER = "FluxShare/Transfer"
    const val CHUNK = "FluxShare/Chunk"
    const val VERIFICATION = "FluxShare/Verification"
    const val SCHEDULER = "FluxShare/Scheduler"

    private fun normalizeTag(tag: String): String {
        return if (tag.startsWith("FluxShare/")) tag else "FluxShare/$tag"
    }

    fun d(tag: String, msg: String) {
        val fullTag = normalizeTag(tag)
        try {
            Log.d(fullTag, msg)
        } catch (_: Throwable) {
            println("[$fullTag] $msg")
        }
    }

    fun i(tag: String, msg: String) {
        val fullTag = normalizeTag(tag)
        try {
            Log.i(fullTag, msg)
        } catch (_: Throwable) {
            println("[$fullTag] $msg")
        }
    }

    fun w(tag: String, msg: String) {
        val fullTag = normalizeTag(tag)
        try {
            Log.w(fullTag, msg)
        } catch (_: Throwable) {
            println("[$fullTag] $msg")
        }
    }

    fun e(tag: String, msg: String, throwable: Throwable? = null) {
        val fullTag = normalizeTag(tag)
        try {
            Log.e(fullTag, msg, throwable)
        } catch (_: Throwable) {
            println("[$fullTag] $msg ${throwable?.message ?: ""}")
        }
    }
}
