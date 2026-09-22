using Microsoft.UI.Xaml.Controls;

namespace Rally.App.Views;

public sealed partial class OnboardingPage : Page
{
    public OnboardingPage()
    {
        InitializeComponent();
    }

    private void Continue_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Frame.Navigate(typeof(SettingsPage));
    }
}
