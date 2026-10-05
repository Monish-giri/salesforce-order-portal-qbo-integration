trigger PartnerUserSharing on User (after insert, after update) {
    Set<Id> userIds = new Set<Id>();
    Set<Id> oldContactIds = new Set<Id>();

    for (User userRecord : Trigger.new) {
        userIds.add(userRecord.Id);

        if (Trigger.isUpdate) {
            User oldUser = Trigger.oldMap.get(userRecord.Id);
            if (oldUser != null && oldUser.ContactId != null) {
                oldContactIds.add(oldUser.ContactId);
            }
        }
    }

    PartnerCustomerAccountSharingService.syncForUserIds(userIds, oldContactIds);
}
