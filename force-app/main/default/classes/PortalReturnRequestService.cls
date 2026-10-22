public with sharing class PortalReturnRequestService {
    @AuraEnabled
    public static Id createReturnRequest(
        Id orderId,
        Map<Id, Decimal> requestedQuantities,
        String reason
    ) {
        try {
            if (orderId == null) {
                throw new AuraHandledException('Order is required.');
            }
            if (requestedQuantities == null || requestedQuantities.isEmpty()) {
                throw new AuraHandledException('Select at least one item to return.');
            }
            return QboReturnRequestService.createReturnRequest(
                orderId,
                requestedQuantities,
                reason
            );
        } catch (QboReturnRequestService.ReturnRequestException ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }
}
