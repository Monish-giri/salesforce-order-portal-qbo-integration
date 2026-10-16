trigger ReturnRequestApproval on Return_Request__c (after insert, after update) {
    Set<Id> approvedIds = new Set<Id>();
    for (Return_Request__c currentRecord : Trigger.new) {
        Boolean approvedNow = currentRecord.Status__c == 'Approved';
        Boolean wasApproved = Trigger.isUpdate && Trigger.oldMap.get(currentRecord.Id).Status__c == 'Approved';
        if (approvedNow && !wasApproved) approvedIds.add(currentRecord.Id);
    }

    if (!approvedIds.isEmpty()) {
        for (Id returnRequestId : approvedIds) {
            System.enqueueJob(new QboCreditMemoJob(returnRequestId));
        }
    }
}
