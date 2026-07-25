package com.samwad

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class MyFirebaseMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        Log.d(TAG, "Message received: ${message.messageId}")
        // Dart background handler handles CallKit UI via _firebaseMessagingBackgroundHandler
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "New FCM Token: $token")
    }

    companion object {
        private const val TAG = "MyFCMService"
    }
}
