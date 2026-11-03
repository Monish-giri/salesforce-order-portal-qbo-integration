({
    handleLogin : function(component, event, helper) {
        var usernameInput = component.find("usernameInput");
        var passwordInput = component.find("passwordInput");
        if (!usernameInput.checkValidity() || !passwordInput.checkValidity()) {
            usernameInput.reportValidity();
            passwordInput.reportValidity();
            return;
        }
        component.set("v.errorMessage", "");
        var action = component.get("c.login");
        action.setParams({
            username: component.get("v.username"),
            password: component.get("v.password"),
            startUrl: "/"
        });
        action.setCallback(this, function(response) {
            if (response.getState() === "SUCCESS") {
                var destination = response.getReturnValue();
                if (destination) {
                    window.location.assign(destination);
                } else {
                    component.set("v.errorMessage", "Unable to sign in. Please check your credentials and try again.");
                }
            } else {
                component.set("v.errorMessage", "Invalid username or password. Please try again.");
            }
        });
        $A.enqueueAction(action);
    }
})