public with sharing class OrderSubmissionService {
    @TestVisible private static Id testContactId;
    @TestVisible private static Id testActorAccountId;
    @TestVisible private static Boolean testIsPartner;
    @TestVisible private static String testPricebookName;

    public class CustomerOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;

        public CustomerOption(Id id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    public class CheckoutContext {
        @AuraEnabled public Id actorAccountId;
        @AuraEnabled public String actorAccountName;
        @AuraEnabled public Boolean isPartner;
        @AuraEnabled public Id defaultOrderAccountId;
        @AuraEnabled public String defaultOrderAccountName;
        @AuraEnabled public List<CustomerOption> customerAccounts = new List<CustomerOption>();
    }

    public class SubmissionResult {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public String paymentMethod;
        @AuraEnabled public Boolean alreadySubmitted;
    }

    private class ActorContext {
        Id contactId;
        Account account;
        Boolean isPartner;
    }

    @AuraEnabled(cacheable=true)
    public static CheckoutContext getCheckoutContext() {
        ActorContext actor = resolveActor();

        CheckoutContext result = new CheckoutContext();
        result.actorAccountId = actor.account.Id;
        result.actorAccountName = actor.account.Name;
        result.isPartner = actor.isPartner;
        result.defaultOrderAccountId = actor.account.Id;
        result.defaultOrderAccountName = actor.account.Name;

        if (actor.isPartner) {
            for (Account customerAccount : [
                SELECT Id, Name
                FROM Account
                WHERE Partner_Account__c = :actor.account.Id
                WITH SYSTEM_MODE
                ORDER BY Name
            ]) {
                result.customerAccounts.add(new CustomerOption(customerAccount.Id, customerAccount.Name));
            }
        }

        return result;
    }

    @AuraEnabled
    public static SubmissionResult submitOrder(
        String cartJson,
        String submissionKey,
        Id orderForAccountId,
        String paymentMethod
    ) {
        if (String.isBlank(cartJson)) {
            throw new AuraHandledException('Your cart is empty.');
        }
        if (String.isBlank(submissionKey) || submissionKey.length() > 100) {
            throw new AuraHandledException('A valid submission key is required.');
        }

        List<Object> rawLines;
        try {
            rawLines = (List<Object>) JSON.deserializeUntyped(cartJson);
        } catch (Exception ex) {
            throw new AuraHandledException('The cart could not be processed.');
        }

        if (rawLines == null || rawLines.isEmpty()) {
            throw new AuraHandledException('Your cart is empty.');
        }

        ActorContext actor = resolveActor();
        String audience = actor.isPartner ? 'Partner' : 'Customer';
        String normalizedPaymentMethod = normalizePaymentMethod(paymentMethod, audience);

        List<Order> existingOrders = [
            SELECT Id, OrderNumber, Account.Name, TotalAmount, Status, Payment_Method__c
            FROM Order
            WHERE Submission_Key__c = :submissionKey
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!existingOrders.isEmpty()) {
            Order existing = existingOrders[0];
            SubmissionResult result = new SubmissionResult();
            result.orderId = existing.Id;
            result.orderNumber = existing.OrderNumber;
            result.accountName = existing.Account.Name;
            result.totalAmount = existing.TotalAmount;
            result.paymentMethod = existing.Payment_Method__c;
            result.alreadySubmitted = true;
            return result;
        }

        Account orderAccount = resolveAuthorizedOrderAccount(actor, orderForAccountId);

        String pricebookName = Test.isRunningTest() && testPricebookName != null
            ? testPricebookName
            : resolvePricebookName(audience);

        Pricebook2 pricebook = getConfiguredPricebook(pricebookName);
        if (pricebook == null) {
            throw new AuraHandledException('No active catalog price book is configured for this portal.');
        }

        Set<Id> pricebookEntryIds = new Set<Id>();
        Map<Id, Integer> quantitiesByEntry = new Map<Id, Integer>();

        for (Object rawLine : rawLines) {
            if (!(rawLine instanceof Map<String, Object>)) {
                throw new AuraHandledException('One or more cart lines are invalid.');
            }

            Map<String, Object> line = (Map<String, Object>) rawLine;
            Id pricebookEntryId;
            try {
                pricebookEntryId = (Id) String.valueOf(line.get('pricebookEntryId'));
            } catch (Exception ex) {
                throw new AuraHandledException('One or more cart products are invalid.');
            }

            if (pricebookEntryId == null || pricebookEntryIds.contains(pricebookEntryId)) {
                throw new AuraHandledException('The cart contains a duplicate or invalid product.');
            }

            Integer quantity;
            try {
                quantity = Integer.valueOf(String.valueOf(line.get('quantity')));
            } catch (Exception ex) {
                throw new AuraHandledException('Each product quantity must be a whole number.');
            }

            if (quantity < 1) {
                throw new AuraHandledException('Each product quantity must be at least 1.');
            }

            pricebookEntryIds.add(pricebookEntryId);
            quantitiesByEntry.put(pricebookEntryId, quantity);
        }

        Map<Id, PricebookEntry> entriesById = new Map<Id, PricebookEntry>([
            SELECT Id, UnitPrice, Product2Id, Product2.Name
            FROM PricebookEntry
            WHERE Id IN :pricebookEntryIds
              AND Pricebook2Id = :pricebook.Id
              AND IsActive = true
              AND Product2.IsActive = true
            WITH SYSTEM_MODE
        ]);

        if (entriesById.size() != pricebookEntryIds.size()) {
            throw new AuraHandledException('One or more cart products are no longer available at the configured price.');
        }

        // Lock the product rows before checking stock so simultaneous checkouts
        // cannot both consume the same available quantity.
        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry entry : entriesById.values()) {
            productIds.add(entry.Product2Id);
        }

        Map<Id, Product2> productsById = new Map<Id, Product2>([
            SELECT Id, Name, Stock_Quantity__c, Minimum_Wholesale_Quantity__c
            FROM Product2
            WHERE Id IN :productIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]);

        Map<Id, Integer> requestedByProduct = new Map<Id, Integer>();
        for (Id entryId : pricebookEntryIds) {
            PricebookEntry entry = entriesById.get(entryId);
            Integer quantity = quantitiesByEntry.get(entryId);
            Product2 product = productsById.get(entry.Product2Id);

            if (product == null) {
                throw new AuraHandledException('One or more cart products could not be validated.');
            }

            if (actor.isPartner) {
                Integer minimumQuantity = product.Minimum_Wholesale_Quantity__c == null
                    ? 1
                    : product.Minimum_Wholesale_Quantity__c.intValue();
                if (quantity < minimumQuantity) {
                    throw new AuraHandledException(
                        product.Name + ' requires a minimum wholesale quantity of ' + minimumQuantity + '.'
                    );
                }
            }

            Integer totalRequested = requestedByProduct.containsKey(product.Id)
                ? requestedByProduct.get(product.Id) + quantity
                : quantity;
            requestedByProduct.put(product.Id, totalRequested);

            Integer availableStock = product.Stock_Quantity__c == null
                ? 0
                : product.Stock_Quantity__c.intValue();
            if (totalRequested > availableStock) {
                throw new AuraHandledException(
                    'Insufficient stock for ' + product.Name + '. Available: ' + availableStock + '.'
                );
            }
        }

        Order newOrder = new Order(
            AccountId = orderAccount.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = pricebook.Id,
            Submission_Key__c = submissionKey,
            Placed_By_Account__c = actor.account.Id,
            Placed_By_Contact__c = actor.contactId,
            Payment_Method__c = normalizedPaymentMethod
        );

        Database.SaveResult orderResult = Database.insert(newOrder, AccessLevel.SYSTEM_MODE);

        if (!orderResult.isSuccess()) {
            throw new AuraHandledException(orderResult.getErrors()[0].getMessage());
        }

        List<OrderItem> orderItems = new List<OrderItem>();
        Decimal expectedTotal = 0;

        for (Id pricebookEntryId : pricebookEntryIds) {
            PricebookEntry entry = entriesById.get(pricebookEntryId);
            Integer quantity = quantitiesByEntry.get(pricebookEntryId);

            orderItems.add(new OrderItem(
                OrderId = newOrder.Id,
                PricebookEntryId = entry.Id,
                Quantity = quantity,
                UnitPrice = entry.UnitPrice
            ));

            expectedTotal += entry.UnitPrice * quantity;
        }

        Database.SaveResult[] itemResults = Database.insert(orderItems, AccessLevel.SYSTEM_MODE);

        for (Database.SaveResult itemResult : itemResults) {
            if (!itemResult.isSuccess()) {
                throw new AuraHandledException(itemResult.getErrors()[0].getMessage());
            }
        }

        // Deduct stock only after the order lines have been inserted successfully.
        // Any later exception rolls back the order, stock changes, and invoice event together.
        List<Product2> productsToUpdate = new List<Product2>();
        for (Id productId : requestedByProduct.keySet()) {
            Product2 product = productsById.get(productId);
            Integer availableStock = product.Stock_Quantity__c == null
                ? 0
                : product.Stock_Quantity__c.intValue();
            product.Stock_Quantity__c = availableStock - requestedByProduct.get(productId);
            productsToUpdate.add(product);
        }

        Database.SaveResult[] stockResults = Database.update(productsToUpdate, AccessLevel.SYSTEM_MODE);
        for (Database.SaveResult stockResult : stockResults) {
            if (!stockResult.isSuccess()) {
                throw new AuraHandledException(
                    'Unable to reserve product stock: ' + stockResult.getErrors()[0].getMessage()
                );
            }
        }

        newOrder.Status = 'Activated';
        Database.SaveResult activationResult = Database.update(newOrder, AccessLevel.SYSTEM_MODE);

        if (!activationResult.isSuccess()) {
            throw new AuraHandledException(activationResult.getErrors()[0].getMessage());
        }

        Database.SaveResult eventResult = EventBus.publish(
            new Order_Invoice_Request__e(Order_Id__c = String.valueOf(newOrder.Id))
        );

        if (!eventResult.isSuccess()) {
            throw new AuraHandledException(
                'Failed to publish invoice request event: ' + eventResult.getErrors()[0].getMessage()
            );
        }

        SubmissionResult result = new SubmissionResult();
        result.orderId = newOrder.Id;
        result.orderNumber = newOrder.OrderNumber;
        result.accountName = orderAccount.Name;
        result.totalAmount = expectedTotal;
        result.paymentMethod = normalizedPaymentMethod;
        result.alreadySubmitted = false;
        return result;
    }

    private static String normalizePaymentMethod(String paymentMethod, String audience) {
        String value = String.isBlank(paymentMethod)
            ? (audience == 'Partner' ? 'Invoice' : 'Online')
            : paymentMethod.trim();

        if (audience == 'Partner') {
            if (value != 'Invoice') {
                throw new AuraHandledException('B2B orders use invoice payment terms.');
            }
            return value;
        }

        if (value != 'Online' && value != 'Cash on Delivery') {
            throw new AuraHandledException('B2C orders can only use Online payment or Cash on Delivery.');
        }

        return value;
    }

    private static ActorContext resolveActor() {
        ActorContext actor = new ActorContext();

        if (Test.isRunningTest() && testActorAccountId != null) {
            actor.account = [
                SELECT Id, Name, IsPartner
                FROM Account
                WHERE Id = :testActorAccountId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            actor.isPartner = testIsPartner == null ? actor.account.IsPartner : testIsPartner;
            actor.contactId = testContactId;
            return actor;
        }

        User currentUser = [
            SELECT ContactId, Contact.AccountId
            FROM User
            WHERE Id = :UserInfo.getUserId()
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (currentUser.ContactId == null || currentUser.Contact.AccountId == null) {
            throw new AuraHandledException('Your portal user is not associated with a customer account.');
        }

        actor.contactId = currentUser.ContactId;
        actor.account = [
            SELECT Id, Name, IsPartner
            FROM Account
            WHERE Id = :currentUser.Contact.AccountId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        actor.isPartner = actor.account.IsPartner;

        return actor;
    }

    private static Account resolveAuthorizedOrderAccount(ActorContext actor, Id orderForAccountId) {
        if (orderForAccountId == actor.account.Id) {
            return actor.account;
        }

        if (!actor.isPartner || orderForAccountId == null) {
            throw new AuraHandledException('You can only place orders for an account you are authorized to use.');
        }

        List<Account> linkedCustomers = [
            SELECT Id, Name
            FROM Account
            WHERE Id = :orderForAccountId
              AND Partner_Account__c = :actor.account.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (linkedCustomers.isEmpty()) {
            throw new AuraHandledException('The selected customer is not linked to your Partner account.');
        }

        return linkedCustomers[0];
    }

    private static String resolvePricebookName(String audience) {
        List<Portal_Catalog_Config__mdt> configs = [
            SELECT Pricebook__c
            FROM Portal_Catalog_Config__mdt
            WHERE Audience__c = :audience
              AND Active__c = true
            ORDER BY DeveloperName
            LIMIT 1
        ];

        return configs.isEmpty() ? null : configs[0].Pricebook__c;
    }

    private static Pricebook2 getConfiguredPricebook(String pricebookName) {
        if (String.isBlank(pricebookName)) {
            return null;
        }

        List<Pricebook2> pricebooks = [
            SELECT Id, Name, IsActive
            FROM Pricebook2
            WHERE Name = :pricebookName
              AND IsActive = true
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        return pricebooks.isEmpty() ? null : pricebooks[0];
    }
}
