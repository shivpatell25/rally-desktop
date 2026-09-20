using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Views;

namespace Rally.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ContentFrame.Navigate(typeof(HomePage));
        Nav.SelectedItem = Nav.MenuItems[0];
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string;
        switch (tag)
        {
            case "home": ContentFrame.Navigate(typeof(HomePage)); break;
            case "multi": ContentFrame.Navigate(typeof(MultiViewPage)); break;
            case "settings": ContentViewNavigate(); break;
        }
    }

    private void ContentViewNavigate() => ContentFrame.Navigate(typeof(SettingsPage));
}
