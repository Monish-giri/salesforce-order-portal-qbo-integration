public with sharing class RazorpayPaymentService {
    private static final String NAMED_CREDENTIAL = 'Razorpay_API';
    private static final String ORDERS_PATH = '/v1/orders';

    public class PaymentOrderResult {
        @AuraEnabled public String razorpayOrderId;
        @AuraEnabled public Integer amountPaise;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currency;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public Decimal discountAmount;
        @AuraEnabled public Decimal invoiceBalance;
        @AuraEnabled public String receipt;
    }

    public class RazorpayPaymentException extends Exception {}

    @AuraEnabled
    public static PaymentOrderResult createPaymentOrder(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('Order is required.');
        }

        // The portal user must be able to see the Order before we switch to
        // system mode for the fields that are written by the integration.
        List<Order> visibleOrders = [
            SELECT Id
            FROM Order
            WHERE Id = :orderId
            WITH USER_MODE
            LIMIT 1
        ];
        if (visibleOrders.isEmpty()) {
            throw new AuraHandledException('The selected order could not be found or is not available to you.');
        }

        Order orderRecord = [
            SELECT Id, OrderNumber, Payment_Method__c, Payment_Status__c,
                   QBO_Invoice_Id__c, QBO_Invoice_Number__c,
                   Invoice_Issue_Date__c, Invoice_Due_Date__c, Invoice_Balance__c,
                   Razorpay_Order_Id__c, Razorpay_Payment_Id__c,
                   Payment_Gateway_Status__c
            FROM Order
            WHERE Id = :orderId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (String.isBlank(orderRecord.QBO_Invoice_Id__c)) {
            throw new AuraHandledException('Online payment is available after the QuickBooks invoice is created.');
        }
        if (orderRecord.Invoice_Balance__c == null || orderRecord.Invoice_Balance__c <= 0) {
            throw new AuraHandledException('There is no outstanding balance to pay on this invoice.');
        }
        if (orderRecord.Payment_Status__c == 'Paid') {
            throw new AuraHandledException('This invoice has already been paid.');
        }
        if (String.isNotBlank(orderRecord.Razorpay_Payment_Id__c) &&
            orderRecord.Payment_Gateway_Status__c == 'Captured') {
            throw new AuraHandledException('A payment has already been captured for this order.');
        }

        B2BEarlyPaymentDiscountService.DiscountResult discount =
            B2BEarlyPaymentDiscountService.calculate(
                orderRecord.Invoice_Issue_Date__c,
                orderRecord.Invoice_Due_Date__c,
                orderRecord.Invoice_Balance__c,
                Date.today()
            );

        Decimal payableAmount = discount.payableAmount > 0
            ? discount.payableAmount
            : orderRecord.Invoice_Balance__c;
        Integer amountPaise = toPaise(payableAmount);
        if (amountPaise <= 0) {
            throw new AuraHandledException('The payment amount must be greater than zero.');
        }

        String receipt = 'SF-' + orderRecord.OrderNumber;
        Map<String, Object> payload = new Map<String, Object>{
            'amount' => amountPaise,
            'currency' => 'INR',
            'receipt' => receipt,
            'notes' => new Map<String, Object>{
                'salesforceOrderId' => String.valueOf(orderRecord.Id),
                'salesforceOrderNumber' => orderRecord.OrderNumber,
                'qboInvoiceId' => orderRecord.QBO_Invoice_Id__c,
                'qboInvoiceNumber' => orderRecord.QBO_Invoice_Number__c
            }
        };

        try {
            Map<String, Object> responsePayload = sendCreateOrder(payload);
            String razorpayOrderId = responsePayload.containsKey('id')
                ? String.valueOf(responsePayload.get('id'))
                : null;

            if (String.isBlank(razorpayOrderId)) {
                throw new RazorpayPaymentException('Razorpay order creation returned no order id.');
            }

            // Store the quote snapshot with the gateway order. The amount used
            // by Checkout is therefore recoverable server-side and cannot be
            // replaced by a client-supplied amount.
            Database.update(new Order(
                Id = orderRecord.Id,
                Razorpay_Order_Id__c = razorpayOrderId,
                Payment_Amount__c = payableAmount,
                Early_Payment_Discount__c = discount.discountAmount,
                Early_Payment_Discount_Percent__c = discount.discountPercent,
                Discount_Eligibility_End__c = getEligibilityEnd(orderRecord.Invoice_Due_Date__c, discount),
                Payment_Gateway_Status__c = 'Order Created'
            ), AccessLevel.SYSTEM_MODE);

            PaymentOrderResult result = new PaymentOrderResult();
            result.razorpayOrderId = razorpayOrderId;
            result.amountPaise = amountPaise;
            result.amount = payableAmount;
            result.currency = 'INR';
            result.discountPercent = discount.discountPercent;
            result.discountAmount = discount.discountAmount;
            result.invoiceBalance = orderRecord.Invoice_Balance__c;
            result.receipt = receipt;
            return result;
        } catch (RazorpayPaymentException ex) {
            markGatewayError(orderRecord.Id);
            throw new AuraHandledException(ex.getMessage());
        } catch (Exception ex) {
            markGatewayError(orderRecord.Id);
            throw new AuraHandledException('Unable to start the online payment. Please try again.');
        }
    }

    private static Map<String, Object> sendCreateOrder(Map<String, Object> payload) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + NAMED_CREDENTIAL + ORDERS_PATH);
        request.setMethod('POST');
        request.setHeader('Accept', 'application/json');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(20000);
        request.setBody(JSON.serialize(payload));

        HttpResponse response = new Http().send(request);
        Integer statusCode = response.getStatusCode();
        if (statusCode < 200 || statusCode >= 300) {
            throw new RazorpayPaymentException(
                'Razorpay order creation failed (' + statusCode + ').'
            );
        }

        if (String.isBlank(response.getBody())) {
            throw new RazorpayPaymentException('Razorpay returned an empty response.');
        }

        try {
            return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        } catch (Exception ex) {
            throw new RazorpayPaymentException('Razorpay returned invalid JSON.');
        }
    }

    private static Integer toPaise(Decimal amount) {
        Decimal rounded = amount.setScale(2);
        return Integer.valueOf(String.valueOf((rounded * 100).setScale(0)));
    }

    private static Date getEligibilityEnd(Date dueDate, B2BEarlyPaymentDiscountService.DiscountResult discount) {
        if (!discount.eligible || dueDate == null || discount.paymentDay == null) {
            return null;
        }
        return dueDate;
    }

    private static void markGatewayError(Id orderId) {
        try {
            Database.update(new Order(
                Id = orderId,
                Payment_Gateway_Status__c = 'Error'
            ), AccessLevel.SYSTEM_MODE);
        } catch (Exception ignored) {
            // Preserve the original payment error rather than masking it with
            // an audit/update failure.
        }
    }
}
