trigger PartnerUserSharing on User (after insert, after update) {
    PartnerCustomerAccountSharingService.syncForUsers(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}
