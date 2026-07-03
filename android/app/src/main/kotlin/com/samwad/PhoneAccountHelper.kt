package com.samwad

import android.content.ComponentName
import android.content.Context
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

object PhoneAccountHelper {
    fun getHandle(context: Context): PhoneAccountHandle {
        val componentName = ComponentName(context, SipConnectionService::class.java)
        return PhoneAccountHandle(componentName, "samvaad_sip")
    }

    fun registerPhoneAccount(context: Context) {
        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val handle = getHandle(context)
        val phoneAccount = PhoneAccount.builder(handle, "Samvaad")
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .build()
        telecomManager.registerPhoneAccount(phoneAccount)
    }
}
