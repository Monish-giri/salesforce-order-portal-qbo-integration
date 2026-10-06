trigger OrderInvoiceRequestTrigger on Order_Invoice_Request__e (after insert) {
    for (Order_Invoice_Request__e event : Trigger.New) {
        if (String.isNotBlank(event.Order_Id__c)) {
            System.enqueueJob(new QboInvoiceJob((Id) event.Order_Id__c));
        }
    }
}
