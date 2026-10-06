@RestResource(urlMapping='/qbo/webhook')
global without sharing class QboWebhookResource {
    @TestVisible
    private static String verifierTokenOverride;

    @HttpPost
    global static void handle() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;

        Blob body = request == null ? null : request.requestBody;
        String signature = request == null ? null : request.getHeader('intuit-signature');

        if (body == null) {
            setResponse(response, 400, '{"error":"Missing request body"}');
            return;
        }

        String verifierToken = getVerifierToken();
        if (String.isBlank(verifierToken)) {
            setResponse(response, 500, '{"error":"Webhook verifier token is not configured"}');
            return;
        }

        String expectedSignature = EncodingUtil.base64Encode(
            Crypto.generateMac('HmacSHA256', body, Blob.valueOf(verifierToken))
        );

        if (String.isBlank(signature) || signature != expectedSignature) {
            setResponse(response, 401, '{"error":"Invalid signature"}');
            return;
        }

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(body.toString());
        } catch (Exception ex) {
            setResponse(response, 400, '{"error":"Invalid JSON"}');
            return;
        }

        Integer queuedCount = 0;
        List<Object> notifications = (List<Object>) payload.get('eventNotifications');

        if (notifications != null) {
            for (Object notificationValue : notifications) {
                if (!(notificationValue instanceof Map<String, Object>)) {
                    continue;
                }

                Map<String, Object> notification = (Map<String, Object>) notificationValue;
                Map<String, Object> dataChangeEvent =
                    (Map<String, Object>) notification.get('dataChangeEvent');

                if (dataChangeEvent == null) {
                    continue;
                }

                List<Object> entities = (List<Object>) dataChangeEvent.get('entities');
                if (entities == null) {
                    continue;
                }

                for (Object entityValue : entities) {
                    if (!(entityValue instanceof Map<String, Object>)) {
                        continue;
                    }

                    Map<String, Object> entity = (Map<String, Object>) entityValue;
                    String entityName = entity.get('name') == null
                        ? null
                        : String.valueOf(entity.get('name'));
                    String entityId = entity.get('id') == null
                        ? null
                        : String.valueOf(entity.get('id'));

                    if (String.isBlank(entityName) || String.isBlank(entityId)) {
                        continue;
                    }

                    System.enqueueJob(new QboPaymentSyncJob(entityName, entityId));
                    queuedCount++;
                }
            }
        }

        insert new QBO_Sync_Log__c(
            Direction__c = 'Inbound',
            Object_Type__c = 'Webhook',
            Operation__c = 'Receive',
            Status__c = 'Success',
            Request_Id__c = 'WEBHOOK-' + String.valueOf(Crypto.getRandomLong()),
            HTTP_Status__c = 200,
            Response_Snippet__c = truncate('Queued events: ' + queuedCount, 255)
        );

        setResponse(response, 200, '{"status":"accepted"}');
    }

    private static String getVerifierToken() {
        if (Test.isRunningTest() && verifierTokenOverride != null) {
            return verifierTokenOverride;
        }

        QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');
        return config == null ? null : config.Webhook_Verifier_Token__c;
    }

    private static void setResponse(RestResponse response, Integer statusCode, String body) {
        if (response == null) {
            return;
        }
        response.statusCode = statusCode;
        response.addHeader('Content-Type', 'application/json');
        response.responseBody = Blob.valueOf(body);
    }

    private static String truncate(String value, Integer maxLength) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }
}
